// Monitor de conectividad real de la aplicación.
//
// PROBLEMA QUE RESUELVE:
//   connectivity_plus detecta si el dispositivo tiene una interfaz de red
//   activa (WiFi conectado, datos móviles encendidos), pero eso NO garantiza
//   que el servidor de la app sea alcanzable. Escenarios donde hay "red"
//   pero no hay conectividad real:
//     · WiFi de hotel/café con portal cautivo (requiere login en browser)
//     · Red conectada pero sin salida a internet
//     · Internet funcionando pero nuestro servidor caído (5xx, deploy, etc.)
//     · DNS fallando para nuestro dominio específico
//
// SOLUCIÓN:
//   Combinamos dos señales:
//     1. connectivity_plus → cambios de interfaz de red (rápido, sin costo)
//     2. Ping HTTP real al servidor → confirma conectividad efectiva
//
//   El estado final [NetworkStatus] refleja la realidad, no solo la interfaz.
//
// TRES ESTADOS:
//   online   → hay red Y el servidor responde
//   offline  → no hay interfaz de red
//   degraded → hay interfaz de red pero el servidor no responde
//
// USO:
//   El OutboxWorker se suscribe al stream [statusStream] y solo procesa
//   la cola cuando el estado es [NetworkStatus.online].

import 'dart:async';
import 'dart:developer';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Estados posibles de conectividad desde la perspectiva de la app.
enum NetworkStatus {
  /// Hay red activa y el servidor de la app responde correctamente.
  /// El OutboxWorker puede procesar la cola con seguridad.
  online,

  /// No hay interfaz de red activa en el dispositivo.
  /// El OutboxWorker debe esperar.
  offline,

  /// Hay interfaz de red pero el servidor no responde.
  /// Puede ser: servidor caído, portal cautivo, DNS fallando, timeout.
  /// El OutboxWorker debe esperar y reintentar el ping periódicamente.
  degraded,
}

/// Monitor de conectividad que combina detección de interfaz de red
/// con verificación real del servidor mediante HTTP ping.
///
/// Se registra como singleton en el inyector de dependencias.
/// El ciclo de vida completo (inicio/pausa) lo maneja [AppDatabase]
/// y el inyector al iniciar la app.
class ConnectivityMonitor {
  ConnectivityMonitor({
    required String serverBaseUrl,
    Duration pingTimeout = const Duration(seconds: 5),
    Duration degradedRetryInterval = const Duration(seconds: 15),
  }) : _serverBaseUrl = serverBaseUrl,
       _pingTimeout = pingTimeout,
       _degradedRetryInterval = degradedRetryInterval;

  final String _serverBaseUrl;
  final Duration _pingTimeout;
  final Duration _degradedRetryInterval;

  // Dio dedicado solo para pings — sin interceptores de retry ni auth
  // para no crear dependencias circulares con DioClient principal.
  final Dio _pingDio = Dio();

  // StreamController broadcast permite múltiples suscriptores
  // (OutboxWorker, SyncEngine, UI) escuchando el mismo stream.
  final _statusController = StreamController<NetworkStatus>.broadcast();

  /// Stream público del estado de conectividad.
  ///
  /// Emite un nuevo [NetworkStatus] cada vez que el estado cambia.
  /// Los suscriptores reciben el estado actual + todos los cambios futuros.
  ///
  /// IMPORTANTE: emite solo cuando hay un CAMBIO de estado, no en cada
  /// ping exitoso. Evita floods de eventos innecesarios en el BLoC.
  Stream<NetworkStatus> get statusStream => _statusController.stream;

  NetworkStatus _currentStatus = NetworkStatus.offline;

  /// Estado actual de conectividad (sincrónico).
  ///
  /// Útil para verificaciones puntuales sin suscribirse al stream.
  /// Ejemplo: el Repository verifica esto antes de intentar un request.
  NetworkStatus get currentStatus => _currentStatus;

  /// Retorna true si hay conectividad efectiva con el servidor.
  bool get isOnline => _currentStatus == NetworkStatus.online;

  // Suscripción a connectivity_plus — se cancela en dispose()
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Timer para reintentar el ping cuando el estado es 'degraded'
  Timer? _degradedRetryTimer;

  // ---------------------------------------------------------------------------
  // CICLO DE VIDA
  // ---------------------------------------------------------------------------

  /// Inicia el monitoreo de conectividad.
  ///
  /// Debe llamarse una vez al iniciar la app, en main.dart o en el
  /// inyector de dependencias después de crear la instancia.
  ///
  /// Pasos:
  ///   1. Verifica el estado inicial de la red
  ///   2. Se suscribe a cambios futuros de connectivity_plus
  Future<void> initialize() async {
    // Verificar estado inicial antes de suscribirse a cambios
    await _checkConnectivity();

    // Suscribirse a cambios de interfaz de red
    // connectivity_plus emite cada vez que el dispositivo conecta/desconecta
    // una interfaz: WiFi on/off, datos móviles on/off, etc.
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
  }

  /// Libera los recursos del monitor.
  ///
  /// Llamar al cerrar la app o en tests para evitar memory leaks.
  void dispose() {
    _connectivitySubscription?.cancel();
    _degradedRetryTimer?.cancel();
    _statusController.close();
  }

  // ---------------------------------------------------------------------------
  // LÓGICA INTERNA
  // ---------------------------------------------------------------------------

  /// Callback ejecutado cuando connectivity_plus detecta un cambio de red.
  ///
  /// [results] lista de interfaces activas. Puede contener múltiples
  /// entradas si el dispositivo tiene WiFi y datos móviles simultáneos.
  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final hasInterface = results.any((r) => r != ConnectivityResult.none);

    if (!hasInterface) {
      // Sin interfaz de red → offline inmediato, sin necesidad de ping
      _updateStatus(NetworkStatus.offline);
      _degradedRetryTimer?.cancel();
    } else {
      // Hay interfaz → verificar si el servidor responde
      await _pingServer();
    }
  }

  /// Verifica el estado actual de red y servidor.
  ///
  /// Flujo:
  ///   1. Consulta connectivity_plus para verificar interfaz de red
  ///   2. Si no hay interfaz → offline
  ///   3. Si hay interfaz → ping al servidor
  ///   4. Si el servidor responde → online
  ///   5. Si el servidor no responde → degraded + inicia retry timer
  Future<void> _checkConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    final hasInterface = results.any((r) => r != ConnectivityResult.none);

    if (!hasInterface) {
      _updateStatus(NetworkStatus.offline);
    } else {
      await _pingServer();
    }
  }

  /// Hace un ping HTTP real al servidor para confirmar conectividad efectiva.
  ///
  /// Usa el endpoint GET /health del backend — un endpoint ultraligero
  /// que solo retorna 200 OK sin tocar la base de datos.
  ///
  /// Si el ping tiene éxito → [NetworkStatus.online]
  /// Si el ping falla (timeout, 5xx, error de red) → [NetworkStatus.degraded]
  ///
  /// En estado degraded, programa un retry periódico con [_degradedRetryTimer]
  /// para detectar cuándo el servidor vuelve a estar disponible.
  Future<void> _pingServer() async {
    try {
      final response = await _pingDio.get(
        '$_serverBaseUrl/health',
        options: Options(
          // Timeout corto para que el usuario no espere demasiado
          sendTimeout: _pingTimeout,
          receiveTimeout: _pingTimeout,
          // No seguir redirects — si hay un portal cautivo que redirige,
          // queremos detectarlo como degraded, no como online.
          followRedirects: false,
          validateStatus: (status) => status == 200,
        ),
      );

      if (response.statusCode == 200) {
        _updateStatus(NetworkStatus.online);
        // Servidor disponible — cancelar el retry timer si estaba activo
        _degradedRetryTimer?.cancel();
        _degradedRetryTimer = null;
      } else {
        _handleDegradedState();
      }
    } catch (e) {
      // Cualquier error (timeout, connection refused, DNS, etc.) = degraded
      log('Connectivity error: $e');
      _handleDegradedState();
    }
  }

  /// Maneja la transición al estado degraded.
  ///
  /// Actualiza el estado y programa pings periódicos para detectar
  /// cuándo el servidor vuelve a estar disponible, sin esperar a que
  /// connectivity_plus detecte un cambio de interfaz (que puede no
  /// ocurrir si la interfaz sigue activa pero el servidor está caído).
  void _handleDegradedState() {
    _updateStatus(NetworkStatus.degraded);

    // Evitar timers duplicados si ya hay uno corriendo
    if (_degradedRetryTimer?.isActive ?? false) return;

    _degradedRetryTimer = Timer.periodic(_degradedRetryInterval, (_) async {
      // Verificar si la interfaz de red sigue activa antes de hacer ping
      final results = await Connectivity().checkConnectivity();
      final hasInterface = results.any((r) => r != ConnectivityResult.none);

      if (hasInterface) {
        await _pingServer();
      } else {
        // Si ya no hay interfaz, pasar a offline y cancelar el timer
        _updateStatus(NetworkStatus.offline);
        _degradedRetryTimer?.cancel();
        _degradedRetryTimer = null;
      }
    });
  }

  /// Actualiza el estado actual y emite al stream SOLO si cambió.
  ///
  /// Evitar emitir el mismo estado dos veces seguidas previene que
  /// el OutboxWorker o el SyncEngine se ejecuten innecesariamente.
  void _updateStatus(NetworkStatus newStatus) {
    debugPrint('🌐 [Connectivity] Estado: ${_currentStatus.name} → ${newStatus.name}');
    if (_currentStatus == newStatus) return;

    _currentStatus = newStatus;
    _statusController.add(newStatus);
  }

  // ---------------------------------------------------------------------------
  // UTILIDADES PÚBLICAS
  // ---------------------------------------------------------------------------

  /// Fuerza una verificación inmediata del estado de conectividad.
  ///
  /// Útil para verificar después de que el usuario realice una acción
  /// manual como "Reintentar" en un mensaje fallido.
  Future<NetworkStatus> forceCheck() async {
    await _checkConnectivity();
    return _currentStatus;
  }
}

/*
Las decisiones de diseño más importantes del archivo:
Por qué dos señales y no solo una — connectivity_plus es reactivo y barato (sin requests HTTP) 
pero solo ve la interfaz de red, no el servidor. 
El ping HTTP es costoso pero certero. 
La combinación da lo mejor de ambos: connectivity_plus dispara el ping solo cuando hay cambio de interfaz, y el ping confirma la realidad.
Estado degraded con retry timer — cuando el servidor no responde pero hay interfaz de red, 
connectivity_plus nunca emitirá un nuevo evento (la interfaz no cambió). 
Sin el Timer.periodic, la app quedaría atascada en degraded para siempre aunque el servidor se recupere. 
El timer cada 15 segundos hace pings silenciosos hasta que el servidor vuelva.
_updateStatus() con guard de igualdad — emite al stream solo cuando el estado realmente cambia. 
Sin esto, cada ping exitoso cada 15 segundos emitiría online repetidamente, despertando innecesariamente al OutboxWorker y al SyncEngine.
followRedirects: false en el ping — detecta portales cautivos (WiFi de hoteles/aeropuertos que redirigen a una página de login). 
Un redirect en el ping se trata como degraded, no como online. 
Sin esto, la app creería tener conexión cuando en realidad no puede llegar al servidor.
forceCheck() — método público para que el usuario pueda tocar "Reintentar" en un mensaje fallido 
y forzar una reverificación inmediata sin esperar el siguiente ciclo del timer.
*/
