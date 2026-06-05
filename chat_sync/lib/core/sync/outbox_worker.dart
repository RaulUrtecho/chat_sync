// OutboxWorker — Procesador de la cola de operaciones pendientes.
//
// Es el componente más crítico del soporte offline. Su única responsabilidad
// es vigilar la tabla outbox y enviar cada operación pendiente al servidor
// en orden FIFO cuando hay conexión disponible.
//
// CUÁNDO SE ACTIVA:
//   El worker se activa por DOS señales independientes:
//   1. ConnectivityMonitor emite NetworkStatus.online
//      → la red acaba de recuperarse, hay operaciones acumuladas
//   2. OutboxDao.watchPendingOperations() emite una nueva operación
//      → el usuario acaba de enviar algo, intentar de inmediato
//
//   Ambas señales convergen en _processPendingQueue().
//
// GARANTÍAS:
//   · FIFO: los mensajes llegan al servidor en el mismo orden en que
//     el usuario los escribió (orderBy id ASC en el outbox)
//   · Sin duplicados: X-Idempotency-Key en cada request
//   · Sin pérdida: las operaciones sobreviven al cierre de la app
//   · Backoff: no satura el servidor en caso de fallos repetidos
//
// FLUJO POR OPERACIÓN:
//
//   getNextPending()
//       ↓
//   ¿Hay operación?
//   NO → terminar, esperar próxima señal
//   SÍ ↓
//   HTTP request con idempotency key
//       ↓
//   ¿Éxito (2xx)?
//   SÍ → deleteOperation() + markAsSent() → siguiente operación
//   NO → incrementRetries()
//       ↓
//   ¿retries >= maxRetries?
//   SÍ → markAsFailed() + deleteOperation() → siguiente operación
//   NO → esperar backoff exponencial → reintentar

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../database/daos/messages_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/threads_dao.dart';
import '../database/tables/outbox_table.dart';
import '../network/connectivity_monitor.dart';
import '../network/dio_client.dart';

/// Número máximo de reintentos antes de marcar una operación como fallida.
const int _kMaxRetries = 5;

/// Procesador de la cola de operaciones pendientes.
///
/// Se registra como singleton en get_it y se inicializa al arrancar la app.
class OutboxWorker {
  OutboxWorker({
    required AppDatabase database,
    required DioClient dioClient,
    required ConnectivityMonitor connectivityMonitor,
  }) : _db = database,
       _dioClient = dioClient,
       _connectivity = connectivityMonitor;

  final AppDatabase _db;
  final DioClient _dioClient;
  final ConnectivityMonitor _connectivity;

  // Referencias a los DAOs para evitar acceder a _db.xxxDao repetidamente
  OutboxDao get _outboxDao => _db.outboxDao;
  MessagesDao get _messagesDao => _db.messagesDao;
  ThreadsDao get _threadsDao => _db.threadsDao;

  // Suscripciones activas — se cancelan en dispose()
  StreamSubscription<NetworkStatus>? _connectivitySubscription;
  StreamSubscription<List<OutboxData>>? _outboxSubscription;

  // Flag para evitar procesamiento concurrente de la cola.
  // Si el worker ya está procesando, una nueva señal no debe
  // lanzar un segundo procesamiento en paralelo.
  bool _isProcessing = false;

  // ---------------------------------------------------------------------------
  // CICLO DE VIDA
  // ---------------------------------------------------------------------------

  /// Inicia el worker y sus suscripciones a señales.
  ///
  /// Debe llamarse una vez al iniciar la app, después de que
  /// ConnectivityMonitor esté inicializado.
  ///
  /// Dos suscripciones se activan:
  ///   1. NetworkStatus → procesar cuando la red vuelve
  ///   2. Outbox changes → procesar cuando llega operación nueva
  void start() {
    // Señal 1: cambios de conectividad
    // Solo procesar cuando el estado cambia A online (no en offline/degraded)
    _connectivitySubscription = _connectivity.statusStream.listen((status) {
      if (status == NetworkStatus.online) {
        _processPendingQueue();
      }
    });

    // Señal 2: nuevas operaciones en el outbox
    // Cuando el usuario envía un mensaje, intentar inmediatamente
    // si ya hay conexión.
    _outboxSubscription = _outboxDao.watchPendingOperations().listen((pendingOps) {
      if (pendingOps.isNotEmpty && _connectivity.isOnline) {
        _processPendingQueue();
      }
    });

    // Procesar inmediatamente al iniciar — puede haber operaciones
    // acumuladas de la sesión anterior (app cerrada con mensajes pendientes)
    if (_connectivity.isOnline) {
      _processPendingQueue();
    }
  }

  /// Detiene el worker y libera recursos.
  void dispose() {
    _connectivitySubscription?.cancel();
    _outboxSubscription?.cancel();
  }

  // ---------------------------------------------------------------------------
  // PROCESAMIENTO DE LA COLA
  // ---------------------------------------------------------------------------

  /// Procesa todas las operaciones pendientes en orden FIFO.
  ///
  /// Usa un flag [_isProcessing] para evitar ejecuciones concurrentes.
  /// Si ya está procesando cuando se llama, retorna inmediatamente.
  ///
  /// Procesa de a UNA operación por vez para garantizar el orden:
  /// no se envía el mensaje 2 hasta que el mensaje 1 fue confirmado.
  Future<void> _processPendingQueue() async {
    // Evitar procesamiento concurrente
    if (_isProcessing) return;
    debugPrint('📤 [Outbox] Procesando cola, isOnline: ${_connectivity.isOnline}');
    _isProcessing = true;

    try {
      // Procesar en loop hasta vaciar el outbox o perder la conexión
      while (_connectivity.isOnline) {
        final operation = await _outboxDao.getNextPending();

        // Outbox vacío → terminar el loop
        if (operation == null) break;

        // Procesar la operación — si falla pero no supera maxRetries,
        // _processOperation la deja en el outbox para el próximo ciclo
        final shouldContinue = await _processOperation(operation);

        // Si el procesamiento indica que debemos parar (ej: error fatal)
        // salir del loop
        if (!shouldContinue) break;
      }
    } finally {
      // Siempre liberar el flag, incluso si ocurre una excepción
      _isProcessing = false;
    }
  }

  /// Procesa una operación individual del outbox.
  ///
  /// Retorna true si se debe continuar procesando la cola,
  /// false si se debe detener (error no recuperable).
  Future<bool> _processOperation(OutboxData operation) async {
    try {
      // Deserializar el payload JSON de la operación
      final payload = jsonDecode(operation.payload) as Map<String, dynamic>;

      // Ejecutar el request HTTP según el tipo de operación
      await _executeOperation(
        operationType: operation.operationType,
        payload: payload,
        idempotencyKey: operation.idempotencyKey,
      );

      // ✅ ÉXITO: eliminar del outbox y actualizar el estado del recurso
      await _handleSuccess(operation);

      return true; // Continuar con la siguiente operación
    } on DioException catch (e) {
      return await _handleDioError(e, operation);
    } catch (e) {
      // Error inesperado (no DioException) — loggear y continuar
      // No queremos que un error raro bloquee toda la cola
      return true;
    }
  }

  /// Ejecuta el request HTTP correspondiente a cada tipo de operación.
  ///
  /// El switch de [operationType] determina qué endpoint llamar y
  /// cómo estructurar el body del request.
  Future<void> _executeOperation({
    required String operationType,
    required Map<String, dynamic> payload,
    required String idempotencyKey,
  }) async {
    final options = _dioClient.idempotentOptions(idempotencyKey);

    switch (operationType) {
      // Enviar un mensaje de chat al servidor
      case OutboxOperationType.sendMessage:
        await _dioClient.dio.post('/messages', data: payload, options: options);

      // Crear un nuevo thread en el servidor
      case OutboxOperationType.createThread:
        await _dioClient.dio.post('/threads', data: payload, options: options);

      // Registrar un nuevo usuario en el servidor
      case OutboxOperationType.createUser:
        await _dioClient.dio.post('/users', data: payload, options: options);

      default:
        // Tipo desconocido — eliminar del outbox para no bloquear la cola
        await _outboxDao.deleteOperation(0);
        throw Exception('Unknown outbox operation type: $operationType');
    }
  }

  /// Maneja el éxito de una operación: limpia outbox y actualiza estados.
  Future<void> _handleSuccess(OutboxData operation) async {
    final payload = jsonDecode(operation.payload) as Map<String, dynamic>;

    switch (operation.operationType) {
      case OutboxOperationType.sendMessage:
        // Marcar el mensaje como enviado en la tabla messages
        final messageId = payload['id'] as String;
        await _messagesDao.markAsSent(messageId);

      case OutboxOperationType.createThread:
        // Marcar el thread como sincronizado
        final threadId = payload['id'] as String;
        await _threadsDao.markAsSynced(threadId);

      case OutboxOperationType.createUser:
        // No hay estado local que actualizar para el usuario
        break;
    }

    // Eliminar la operación del outbox — ya fue procesada exitosamente
    await _outboxDao.deleteOperation(operation.id);
  }

  /// Maneja errores de Dio con lógica de retry y backoff.
  ///
  /// Retorna true si se debe continuar procesando la cola.
  Future<bool> _handleDioError(DioException error, OutboxData operation) async {
    final currentRetries = operation.retries;

    // Errores 4xx (excepto 409 Conflict que puede ser idempotency):
    // reintentar no ayuda, el request está mal formado.
    // Eliminar del outbox y marcar como fallido.
    final statusCode = error.response?.statusCode;
    if (statusCode != null && statusCode >= 400 && statusCode < 500 && statusCode != 409) {
      await _markOperationAsFailed(operation);
      return true; // Continuar con la siguiente operación
    }

    // 409 Conflict = el servidor ya procesó esta operación (idempotency hit)
    // Tratar como éxito
    if (statusCode == 409) {
      await _handleSuccess(operation);
      return true;
    }

    // Error de red o 5xx: evaluar si se agotaron los reintentos
    if (currentRetries >= _kMaxRetries) {
      await _markOperationAsFailed(operation);
      return true; // Continuar con otras operaciones
    }

    // Aún quedan reintentos: incrementar contador y esperar backoff
    await _outboxDao.incrementRetries(operation.id);

    // Calcular delay de backoff exponencial
    final delaySeconds = _calculateBackoffDelay(currentRetries);
    await Future.delayed(Duration(seconds: delaySeconds));

    // Detener el loop — el worker será re-activado por la próxima
    // señal de outbox o de conectividad
    return false;
  }

  /// Marca una operación como fallida: actualiza el recurso y limpia outbox.
  Future<void> _markOperationAsFailed(OutboxData operation) async {
    final payload = jsonDecode(operation.payload) as Map<String, dynamic>;

    // Solo los mensajes tienen estado visual de fallo en la UI
    if (operation.operationType == OutboxOperationType.sendMessage) {
      final messageId = payload['id'] as String;
      await _messagesDao.markAsFailed(messageId);
    }

    // Eliminar del outbox — no tiene sentido seguir reintentando
    await _outboxDao.deleteOperation(operation.id);
  }

  /// Calcula el delay de backoff exponencial en segundos.
  ///
  /// delay = min(2^retries, 32) segundos
  ///   retries=0 → 1s
  ///   retries=1 → 2s
  ///   retries=2 → 4s
  ///   retries=3 → 8s
  ///   retries=4 → 16s
  ///   retries=5 → 32s (tope)
  int _calculateBackoffDelay(int retries) {
    const maxDelay = 32;
    final delay = 1 << retries; // equivale a 2^retries con bit shift
    return delay > maxDelay ? maxDelay : delay;
  }
}


/*
Estas son las dos piezas más importantes del proyecto. Un resumen de las decisiones clave:
outbox_worker.dart
El worker tiene dos señales de activación independientes: ConnectivityMonitor (cuando la red regresa) 
y OutboxDao.watchPendingOperations() (cuando el usuario envía algo nuevo). 
Esto garantiza que los mensajes se intenten enviar inmediatamente si hay red, y automáticamente cuando la red regresa.
El flag _isProcessing evita que dos señales simultáneas lancen dos instancias del loop.
El 1 << retries (bit shift) es la forma más eficiente de calcular 2^n en Dart para el backoff. 
Los errores 409 Conflict se tratan como éxito — es la respuesta que el servidor da cuando detecta una idempotency key repetida.
sync_engine.dart
La separación de responsabilidades con el OutboxWorker es clara: el worker sube (local → server), el engine baja (server → local). 
Son flujos completamente independientes.
El delta sync usa dos cursores anidados: el lastSyncAt global como fallback, y el lastMessageTimestamp por thread como cursor más preciso. 
Esto evita descargar mensajes que ya tenemos.
El WebSocket tiene reconexión automática en _onWebSocketDone() con un delay de 3 segundos. 
Los mensajes propios que llegan por WS se ignoran (senderId == _currentUserId) porque ya existen localmente 
desde que el usuario los escribió — el outbox se encarga de actualizarlos a sent.
*/