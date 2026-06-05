// SyncEngine — Motor de sincronización delta al reconectar.
//
// RESPONSABILIDADES:
//   1. Delta Sync: al recuperar la conexión, pedir solo los mensajes
//      y threads que llegaron mientras la app estaba offline.
//   2. WebSocket: mantener la conexión en tiempo real cuando hay red,
//      y reconectar automáticamente cuando se pierde.
//
// DIFERENCIA CON OUTBOX WORKER:
//   OutboxWorker → LOCAL a SERVIDOR (enviar lo que el usuario creó offline)
//   SyncEngine   → SERVIDOR a LOCAL (recibir lo que otros enviaron mientras
//                  el usuario estaba offline)
//
//   Son dos flujos complementarios que juntos garantizan la sincronización
//   bidireccional completa.
//
// DELTA SYNC — CÓMO FUNCIONA:
//
//   En lugar de pedir toda la historia cada vez que hay reconexión
//   (costoso en datos y tiempo), pedimos solo lo nuevo:
//
//     GET /threads?userId={id}&since={lastSyncAt}
//     GET /messages/{threadId}?since={lastMessageTimestamp}
//
//   [lastSyncAt] se almacena en SharedPreferences y se actualiza
//   al final de cada sync exitoso.
//
// WEBSOCKET — FLUJO EN TIEMPO REAL:
//
//   Conexión activa → mensajes nuevos llegan como eventos WS
//                  → se insertan directamente en la DB local
//                  → Drift emite en sus streams
//                  → UI se actualiza sin polling
//
//   Conexión perdida → SyncEngine detecta el cierre del WS
//                   → espera reconexión de ConnectivityMonitor
//                   → al reconectar: delta sync primero, luego re-WS

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../database/app_database.dart';
import '../database/daos/messages_dao.dart';
import '../database/daos/threads_dao.dart';
import '../network/connectivity_monitor.dart';
import '../network/dio_client.dart';

/// Clave para almacenar el timestamp del último sync en SharedPreferences.
const String _kLastSyncKey = 'last_sync_at';

/// Motor de sincronización delta y gestor de WebSocket.
///
/// Se registra como singleton en get_it y se inicializa al arrancar
/// la app, después de ConnectivityMonitor.
class SyncEngine {
  SyncEngine({
    required AppDatabase database,
    required DioClient dioClient,
    required ConnectivityMonitor connectivityMonitor,
    required SharedPreferences sharedPreferences,
    required String wsBaseUrl,
    required String currentUserId,
  }) : _db = database,
       _dioClient = dioClient,
       _connectivity = connectivityMonitor,
       _prefs = sharedPreferences,
       _wsBaseUrl = wsBaseUrl,
       _currentUserId = currentUserId;

  final AppDatabase _db;
  final DioClient _dioClient;
  final ConnectivityMonitor _connectivity;
  final SharedPreferences _prefs;
  final String _wsBaseUrl;
  final String _currentUserId;

  MessagesDao get _messagesDao => _db.messagesDao;
  ThreadsDao get _threadsDao => _db.threadsDao;

  // WebSocket
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  bool _isWsConnected = false;

  // Suscripción al monitor de conectividad
  StreamSubscription<NetworkStatus>? _connectivitySubscription;

  // Flag para evitar delta syncs concurrentes
  bool _isSyncing = false;

  // ---------------------------------------------------------------------------
  // CICLO DE VIDA
  // ---------------------------------------------------------------------------

  /// Inicia el motor de sincronización.
  ///
  /// Pasos al iniciar:
  ///   1. Suscribirse a cambios de conectividad
  ///   2. Si hay conexión: delta sync + conectar WebSocket
  void start() {
    _connectivitySubscription = _connectivity.statusStream.listen(_onConnectivityChanged);

    // Si ya hay conexión al iniciar, sincronizar de inmediato
    if (_connectivity.isOnline) {
      _onConnectivityChanged(NetworkStatus.online);
    }
  }

  /// Detiene el motor y libera todos los recursos.
  void dispose() {
    _connectivitySubscription?.cancel();
    _disconnectWebSocket();
  }

  // ---------------------------------------------------------------------------
  // MANEJADOR DE CAMBIOS DE CONECTIVIDAD
  // ---------------------------------------------------------------------------

  /// Reacciona a los cambios de estado de la red.
  ///
  /// Online  → delta sync + conectar/reconectar WebSocket
  /// Offline/Degraded → desconectar WebSocket (conservar batería y recursos)
  Future<void> _onConnectivityChanged(NetworkStatus status) async {
    if (status == NetworkStatus.online) {
      // Siempre hacer delta sync antes de conectar el WebSocket.
      // Esto asegura que los mensajes que llegaron mientras estábamos
      // offline se persistan localmente antes de empezar a recibir
      // mensajes nuevos en tiempo real.
      await _performDeltaSync();
      _connectWebSocket();
    } else {
      // Sin conexión → desconectar WS para no desperdiciar recursos
      // intentando reconectar a un servidor inalcanzable.
      _disconnectWebSocket();
    }
  }

  // ---------------------------------------------------------------------------
  // DELTA SYNC
  // ---------------------------------------------------------------------------

  /// Sincroniza los datos que llegaron mientras la app estaba offline.
  ///
  /// Pedimos solo lo nuevo usando el timestamp [lastSyncAt] como cursor.
  /// Al final del sync, actualizamos [lastSyncAt] para el próximo ciclo.
  Future<void> _performDeltaSync() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      // Obtener el timestamp de la última sincronización exitosa
      final lastSyncAt = _getLastSyncTimestamp();
      final sinceParam = lastSyncAt?.toUtc().toIso8601String();

      // Paso 1: Sincronizar threads nuevos o actualizados
      await _syncThreads(sinceParam);

      // Paso 2: Sincronizar mensajes nuevos en todos los threads conocidos
      await _syncAllMessages(sinceParam);

      // Paso 3: Actualizar el cursor de sincronización
      await _updateLastSyncTimestamp(DateTime.now().toUtc());
    } on DioException {
      // Error de red durante el sync — no es crítico, el próximo
      // evento de reconexión volverá a intentarlo
    } finally {
      _isSyncing = false;
    }
  }

  /// Sincroniza threads del servidor que el usuario no tiene localmente
  /// o que han sido actualizados desde la última sincronización.
  Future<void> _syncThreads(String? sinceParam) async {
    final queryParams = <String, dynamic>{'userId': _currentUserId};
    if (sinceParam != null) queryParams['since'] = sinceParam;

    final response = await _dioClient.dio.get('/threads', queryParameters: queryParams);

    final threadsJson = response.data as List<dynamic>;

    for (final json in threadsJson) {
      final map = json as Map<String, dynamic>;
      final participantId = map['participant_id'] as String;
      final participantName = map['participant_name'] as String? ?? 'Usuario';

      // Cachear el participante ANTES de insertar el thread
      await _db.usersDao.insertUser(
        UsersCompanion(
          id: Value(participantId),
          name: Value(participantName),
          isCurrentUser: const Value(false),
          createdAt: Value(DateTime.now().toUtc()),
        ),
      );
    }

    // Convertir cada JSON a un ThreadsCompanion para insertar/actualizar
    final companions = threadsJson.map((json) {
      final map = json as Map<String, dynamic>;
      return ThreadsCompanion(
        id: Value(map['id'] as String),
        participantId: Value(map['participant_id'] as String),
        lastMessage: Value(map['last_message'] as String?),
        lastMessageAt: Value(map['last_message_at'] != null ? DateTime.parse(map['last_message_at'] as String) : null),
        // Los threads del servidor ya están sincronizados
        syncStatus: const Value('synced'),
        createdAt: Value(DateTime.parse(map['created_at'] as String)),
      );
    }).toList();

    // Insertar todos en una sola transacción
    // insertOrReplace actualiza si ya existe (puede haber lastMessage nuevo)
    if (companions.isNotEmpty) {
      await _db.batch((batch) {
        batch.insertAllOnConflictUpdate(_db.threads, companions);
      });
    }
  }

  /// Sincroniza mensajes nuevos para todos los threads conocidos.
  ///
  /// Por cada thread local, pedimos los mensajes creados después del
  /// último mensaje que tenemos en la DB local.
  Future<void> _syncAllMessages(String? sinceParam) async {
    // Obtener todos los threads locales
    final localThreads = await (_db.select(_db.threads)).get();

    // Sincronizar mensajes de cada thread en paralelo
    // (Promise.all equivalente en Dart)
    await Future.wait(localThreads.map((thread) => _syncMessagesForThread(thread.id, sinceParam)));
  }

  /// Sincroniza mensajes nuevos para un thread específico.
  ///
  /// Usa el timestamp del último mensaje local como cursor (delta sync).
  /// Si no hay mensajes locales, descarga todos los del thread.
  Future<void> _syncMessagesForThread(String threadId, String? globalSince) async {
    // Preferir el timestamp del último mensaje del thread sobre el global
    final lastMessageAt = await _messagesDao.getLastMessageTimestamp(threadId);
    final sinceParam = lastMessageAt?.toUtc().toIso8601String() ?? globalSince;

    final queryParams = <String, dynamic>{};
    if (sinceParam != null) queryParams['since'] = sinceParam;

    final response = await _dioClient.dio.get('/messages/$threadId', queryParameters: queryParams);

    final messagesJson = response.data as List<dynamic>;
    if (messagesJson.isEmpty) return;

    // Convertir a companions — estos mensajes vienen del servidor,
    // así que su status siempre es 'received' y syncStatus 'synced'
    final companions = messagesJson.map((json) {
      final map = json as Map<String, dynamic>;
      final senderId = map['sender_id'] as String;
      final isOwnMessage = senderId == _currentUserId;

      return MessagesCompanion(
        id: Value(map['id'] as String),
        threadId: Value(map['thread_id'] as String),
        senderId: Value(senderId),
        content: Value(map['content'] as String),
        // Mensajes propios que vienen del server = sent (ya fueron confirmados)
        // Mensajes de otros = received
        status: Value(isOwnMessage ? 'sent' : 'received'),
        syncStatus: const Value('synced'),
        createdAt: Value(DateTime.parse(map['created_at'] as String)),
      );
    }).toList();

    await _messagesDao.insertMessages(companions);

    // Actualizar el lastMessage del thread con el mensaje más reciente
    final lastMsg = companions.last;
    await _threadsDao.updateLastMessage(
      threadId: threadId,
      lastMessage: lastMsg.content.value,
      lastMessageAt: lastMsg.createdAt.value,
    );
  }

  // ---------------------------------------------------------------------------
  // WEBSOCKET
  // ---------------------------------------------------------------------------

  /// Establece la conexión WebSocket con el servidor.
  ///
  /// El servidor Go espera una conexión en:
  ///   ws://{host}/ws?userId={currentUserId}
  ///
  /// Todos los mensajes nuevos que lleguen al servidor para este usuario
  /// serán enviados a través de esta conexión.
  void _connectWebSocket() {
    if (_isWsConnected) return; // Ya conectado

    final wsUri = Uri.parse('$_wsBaseUrl/ws?userId=$_currentUserId');
    debugPrint('🔌 [WS] Conectando a: $wsUri');

    try {
      _wsChannel = WebSocketChannel.connect(wsUri);
      _isWsConnected = true;
      debugPrint('🔌 [WS] Conexión establecida');

      // Suscribirse a mensajes entrantes del WebSocket
      _wsSubscription = _wsChannel!.stream.listen(
        (data) {
          debugPrint('📨 [WS] Mensaje recibido: $data');
          _onWebSocketMessage(data);
        },
        onError: (error) {
          debugPrint('❌ [WS] Error: $error');
          _onWebSocketError(error);
        },
        onDone: () {
          debugPrint('🔌 [WS] Conexión cerrada');
          _onWebSocketDone();
        },
      );
    } catch (_) {
      _isWsConnected = false;
    }
  }

  /// Desconecta el WebSocket de forma limpia.
  void _disconnectWebSocket() {
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    _wsChannel = null;
    _isWsConnected = false;
  }

  /// Procesa un mensaje recibido por WebSocket.
  ///
  /// El servidor envía eventos JSON con la siguiente estructura:
  /// ```json
  /// {
  ///   "type": "new_message",
  ///   "data": {
  ///     "id": "uuid",
  ///     "thread_id": "uuid",
  ///     "sender_id": "uuid",
  ///     "content": "Hola!",
  ///     "created_at": "2024-01-15T10:30:00Z"
  ///   }
  /// }
  /// ```
  Future<void> _onWebSocketMessage(dynamic rawMessage) async {
    try {
      final event = jsonDecode(rawMessage as String) as Map<String, dynamic>;
      final eventType = event['type'] as String;
      final data = event['data'] as Map<String, dynamic>;

      switch (eventType) {
        case 'new_message':
          await _handleIncomingMessage(data);
        case 'thread_synced':
          // El servidor confirma que un thread fue creado exitosamente
          final threadId = data['id'] as String;
          await _threadsDao.markAsSynced(threadId);
        // Agregar más tipos de eventos según sea necesario
      }
    } catch (_) {
      // Mensaje malformado — ignorar y continuar
    }
  }

  /// Persiste un mensaje entrante en la base de datos local.
  ///
  /// Drift emitirá automáticamente en watchMessages() del thread
  /// correspondiente, y la UI se actualizará sin código adicional.
  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    debugPrint('📨 [WS] Procesando mensaje: $data');
    final senderId = data['sender_id'] as String;

    // Ignorar mensajes propios que ya guardamos localmente cuando
    // el usuario los envió. El outbox se encarga de actualizarlos a 'sent'.
    if (senderId == _currentUserId) {
      debugPrint('📨 [WS] Mensaje propio, ignorando');
      return;
    }

    final threadId = data['thread_id'] as String;

    // Si el thread no existe localmente, sincronizar threads primero
    // Esto ocurre cuando el receptor recibe un mensaje de un thread
    // que fue creado mientras no tenía la app abierta
    final thread = await _threadsDao.getThreadById(threadId);
    if (thread == null) {
      await _syncThreads(null);
    }

    final companion = MessagesCompanion(
      id: Value(data['id'] as String),
      threadId: Value(threadId),
      senderId: Value(senderId),
      content: Value(data['content'] as String),
      status: const Value('received'),
      syncStatus: const Value('synced'),
      createdAt: Value(DateTime.parse(data['created_at'] as String)),
    );

    // insertOrIgnore: si el delta sync ya lo insertó, no duplicar
    await _messagesDao.insertMessage(companion);

    // Actualizar el lastMessage del thread para refrescar la thread card
    await _threadsDao.updateLastMessage(
      threadId: companion.threadId.value,
      lastMessage: companion.content.value,
      lastMessageAt: companion.createdAt.value,
    );
  }

  /// Maneja errores del WebSocket.
  void _onWebSocketError(Object error) {
    _isWsConnected = false;
    // El ConnectivityMonitor detectará si es un problema de red
    // y emitirá el estado apropiado para reconectar
  }

  /// Se ejecuta cuando el servidor cierra la conexión WebSocket.
  ///
  /// Puede ocurrir por: deploy del servidor, timeout de inactividad,
  /// reinicio del servidor, etc. Intentar reconectar si hay red.
  void _onWebSocketDone() {
    _isWsConnected = false;

    // Si seguimos online, intentar reconectar después de un breve delay
    if (_connectivity.isOnline) {
      Future.delayed(const Duration(seconds: 3), () {
        // Re-verificar en el momento de ejecutar, no cuando se schedula
        if (_connectivity.isOnline) {
          _connectWebSocket();
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // PERSISTENCIA DEL CURSOR DE SINCRONIZACIÓN
  // ---------------------------------------------------------------------------

  /// Obtiene el timestamp de la última sincronización exitosa.
  ///
  /// Retorna null en la primera ejecución (nunca se ha sincronizado),
  /// lo que hace que el sync descargue toda la historia disponible.
  DateTime? _getLastSyncTimestamp() {
    final stored = _prefs.getString(_kLastSyncKey);
    if (stored == null) return null;
    return DateTime.tryParse(stored);
  }

  /// Almacena el timestamp del sync actual para el próximo delta sync.
  Future<void> _updateLastSyncTimestamp(DateTime timestamp) async {
    await _prefs.setString(_kLastSyncKey, timestamp.toIso8601String());
  }
}
