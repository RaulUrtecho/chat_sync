// ChatRepository — Orquestador de datos.
//
// Es el único punto de contacto entre los BLoCs y los datos.
// Decide en cada operación si usar local, remoto, o ambos.
//
// REGLA FUNDAMENTAL:
//   Escribir siempre en local primero, sincronizar en background.
//   Leer siempre desde local — nunca bloquear la UI esperando red.
//
// FLUJO POR TIPO DE OPERACIÓN:
//
//   ESCRITURA (sendMessage, createUser):
//     1. Guardar localmente (inmediato)
//     2. Registrar en outbox (inmediato)
//     3. Retornar → UI ya tiene el dato
//     4. OutboxWorker sincroniza en background (asíncrono)
//
//   LECTURA REACTIVA (watchMessages, watchThreads):
//     Retornar el Stream de Drift directamente.
//     La UI se suscribe y se actualiza automáticamente cuando
//     cambia la DB local (por outbox sync, delta sync, o WebSocket).
//
//   BÚSQUEDA (searchUsers):
//     1. Buscar localmente (instantáneo, sin red)
//     2. Si hay red: buscar también en servidor en background
//     3. Cachear resultados del servidor localmente
//     4. El stream local emite con los nuevos resultados
//     → El usuario ve resultados instantáneos que se enriquecen si hay red

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/connectivity_monitor.dart';
import '../domain/entities/message_entity.dart';
import '../domain/entities/thread_entity.dart';
import '../domain/entities/user_entity.dart';
import 'local/chat_local_ds.dart';
import 'remote/chat_api.dart';

/// Repositorio principal de la feature de chat.
///
/// Los BLoCs reciben esta clase por inyección de dependencias
/// y la usan para todas las operaciones de datos.
class ChatRepository {
  ChatRepository({
    required ChatLocalDs localDs,
    required ChatApi remoteApi,
    required ConnectivityMonitor connectivityMonitor,
    required SharedPreferences sharedPreferences,
  }) : _local = localDs,
       _remote = remoteApi,
       _connectivity = connectivityMonitor,
       _prefs = sharedPreferences;

  final ChatLocalDs _local;
  final ChatApi _remote;
  final ConnectivityMonitor _connectivity;
  final SharedPreferences _prefs;
  final _uuid = const Uuid();

  String? get _currentUserId => _prefs.getString('current_user_id');

  // ---------------------------------------------------------------------------
  // USUARIOS
  // ---------------------------------------------------------------------------

  /// Registra un nuevo usuario en el sistema.
  ///
  /// FLUJO:
  ///   1. Genera un UUID para el nuevo usuario
  ///   2. Guarda localmente con isCurrentUser: true
  ///   3. Registra en SharedPreferences para acceso rápido
  ///   4. Si hay red: registra en servidor de inmediato
  ///   5. Si no hay red: el outbox lo sincronizará después
  ///
  /// Retorna la entidad del usuario creado.
  Future<UserEntity> createUser(String name) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc();

    final user = UserEntity(id: id, name: name, isCurrentUser: true, createdAt: now);

    // Guardar localmente siempre — independiente de la red
    await _local.saveCurrentUser(user);

    // Intentar registro inmediato en servidor si hay conexión
    // Si falla o no hay red, el outbox se encarga de sincronizar
    if (_connectivity.isOnline) {
      try {
        await _remote.createUser(
          id: id,
          name: name,
          options: Options(headers: {'X-Idempotency-Key': id}),
        );
      } on DioException {
        // No es crítico — el outbox reintentará
        // El usuario puede usar la app sin esperar confirmación del servidor
      }
    }

    return user;
  }

  /// Envía el FCM token actual al servidor.
  ///
  /// Se llama en cada arranque de la app y cuando FCM rota el token.
  Future<void> updateFCMToken(String fcmToken) async {
    final userId = _currentUserId;
    if (userId == null) return;
    if (!_connectivity.isOnline) return;

    try {
      await _remote.updateFCMToken(userId: userId, fcmToken: fcmToken);
    } on DioException {
      // No crítico — se reintentará en el próximo arranque
    }
  }

  /// Obtiene el usuario actual desde la DB local.
  Future<UserEntity?> getCurrentUser() => _local.getCurrentUser();

  /// Stream del usuario actual.
  Stream<UserEntity?> watchCurrentUser() => _local.watchCurrentUser();

  /// Busca usuarios por nombre — local + remoto en paralelo.
  ///
  /// ESTRATEGIA:
  ///   · Resultados locales: instantáneos (sin esperar red)
  ///   · Resultados remotos: si hay red, enriquecen la búsqueda
  ///
  /// Retorna los resultados locales inmediatamente y dispara la
  /// búsqueda remota en background. Los resultados remotos se
  /// cachean localmente, lo que actualiza el stream del llamador.
  Future<List<UserEntity>> searchUsers(String query) async {
    // Siempre buscar localmente primero
    final localResults = await _local.searchUsersLocally(query);

    // Enriquecer con resultados del servidor si hay red
    if (_connectivity.isOnline) {
      try {
        final remoteResults = await _remote.searchUsers(query);
        final remoteUsers = remoteResults.map(_mapRemoteUser).toList();

        // Cachear usuarios remotos localmente para búsquedas futuras offline
        await _local.cacheUsers(remoteUsers);

        // Combinar: remoto tiene precedencia (más completo), agregar locales
        // que no estén en el resultado remoto
        final remoteIds = remoteUsers.map((u) => u.id).toSet();
        final onlyLocal = localResults.where((u) => !remoteIds.contains(u.id)).toList();

        return [...remoteUsers, ...onlyLocal];
      } on DioException {
        // Sin red o error: retornar solo resultados locales
        return localResults;
      }
    }

    return localResults;
  }

  /// Carga los threads del servidor y los persiste localmente.
  ///
  /// Se llama desde ThreadsBloc al iniciar para poblar la DB local
  /// si está vacía o desactualizada. Corre en paralelo con la
  /// suscripción al stream de Drift — cuando persiste los threads,
  /// Drift los emite automáticamente y la UI se actualiza.
  ///
  /// FLUJO:
  ///   1. Verificar conectividad y userId
  ///   2. Pedir threads al servidor (con delta sync si hay cursor)
  ///   3. Por cada thread: cachear el usuario participante
  ///   4. Persistir el thread localmente
  ///   → Drift emite en watchThreads() → ThreadsBloc emite ThreadsLoaded
  Future<void> fetchAndCacheThreads() async {
    if (!_connectivity.isOnline) return;
    final userId = _currentUserId;
    if (userId == null) return;

    try {
      // Pedir threads al servidor
      // Sin cursor 'since' — queremos todos los threads del usuario
      final remoteThreads = await _remote.getThreads();

      for (final threadJson in remoteThreads) {
        final threadId = threadJson['id'] as String;
        final participantId = threadJson['participant_id'] as String;

        // Cachear el usuario participante localmente para que su nombre
        // esté disponible offline en la thread card sin queries adicionales
        // Buscamos el participante en local primero para no sobreescribir
        // datos que ya tengamos
        final existingParticipant = await _local.getUserById(participantId);

        if (existingParticipant == null) {
          // El participante no está cacheado — buscarlo en el servidor
          // Reutilizamos searchUsers con su nombre si viene en el thread
          // o hacemos un lookup directo si el backend lo soporta.
          // Por ahora lo creamos con los datos mínimos disponibles en el thread.
          // El nombre completo llegará cuando el usuario lo busque en el search.
          final participantEntity = UserEntity(
            id: participantId,
            name: threadJson['participant_name'] as String? ?? 'Usuario',
            createdAt: DateTime.now().toUtc(),
          );
          await _local.cacheUser(participantEntity);
        }

        // Persistir el thread localmente
        // getOrCreateThread verifica si ya existe antes de insertar
        final participant =
            existingParticipant ??
            UserEntity(
              id: participantId,
              name: threadJson['participant_name'] as String? ?? 'Usuario',
              createdAt: DateTime.now().toUtc(),
            );

        await _local.getOrCreateThread(
          threadId: threadId,
          participant: participant,
          currentUserId: userId,
          // Pasar syncStatus 'synced' porque viene del servidor
          syncStatus: 'synced',
        );
      }
    } on DioException {
      // No es crítico — el stream local ya tiene lo que hay
      // Si hay threads en local, la UI los mostrará de todas formas
    }
  }

  // ---------------------------------------------------------------------------
  // THREADS
  // ---------------------------------------------------------------------------

  /// Stream de todos los threads del usuario actual.
  ///
  /// El ThreadsBloc se suscribe a este stream. Cada vez que cambia
  /// cualquier thread (nuevo mensaje, sync completado), Drift emite
  /// automáticamente y la lista se actualiza en la UI.
  Stream<List<ThreadEntity>> watchThreads() => _local.watchThreads();

  /// Obtiene o crea un thread para chatear con un usuario.
  ///
  /// Si ya existe un thread con este participante → retorna el existente.
  /// Si no existe → crea uno localmente y lo encola en outbox.
  Future<ThreadEntity> getOrCreateThread(UserEntity participant) async {
    final currentUserId = _currentUserId!;
    final threadId = _generateThreadId(currentUserId, participant.id);

    return _local.getOrCreateThread(threadId: threadId, participant: participant, currentUserId: currentUserId);
  }

  // ---------------------------------------------------------------------------
  // MENSAJES
  // ---------------------------------------------------------------------------

  /// Stream de mensajes de un thread.
  ///
  /// El ChatBloc se suscribe a este stream. Emite automáticamente cuando:
  ///   · El usuario envía un mensaje nuevo (insertado con pending)
  ///   · El OutboxWorker confirma un mensaje (pending → sent)
  ///   · Llega un mensaje vía WebSocket (received)
  ///   · El delta sync inserta mensajes del servidor
  Stream<List<MessageEntity>> watchMessages(String threadId) => _local.watchMessages(threadId);

  /// Envía un mensaje — operación central del proyecto.
  ///
  /// FLUJO COMPLETO (Optimistic UI + Outbox):
  ///   1. Generar UUID para el mensaje (en el cliente)
  ///   2. Insertar en messages con status: 'pending'
  ///   3. Insertar en outbox con idempotencyKey = message.id
  ///   4. Actualizar lastMessage del thread
  ///   Todo en UNA transacción atómica.
  ///   5. Retornar → UI muestra ⏱ inmediatamente
  ///   6. OutboxWorker procesa la cola en background
  ///   7. Al confirmar el servidor → status cambia a ✓
  ///   8. Si falla N veces → status cambia a ✗
  Future<MessageEntity> sendMessage({required String threadId, required String content}) async {
    final currentUserId = _currentUserId!;
    final messageId = _uuid.v4();
    final now = DateTime.now().toUtc();

    final message = MessageEntity(
      id: messageId,
      threadId: threadId,
      senderId: currentUserId,
      content: content,
      status: MessageStatus.pending,
      createdAt: now,
      isFromCurrentUser: true,
    );

    // Guardar localmente + encolar en outbox (transacción atómica)
    // La UI verá el mensaje inmediatamente vía el stream de Drift
    await _local.saveMessageWithOutbox(message);

    return message;
  }

  /// Reintenta un mensaje fallido: resetea a 'pending' y re-encola en outbox.
  ///
  /// Se llama desde ChatBloc cuando el usuario toca "Reintentar" en un
  /// mensaje con status 'failed' ✗. El OutboxWorker lo procesará en el
  /// próximo ciclo si hay conexión disponible.
  Future<void> retryFailedMessage(String messageId) async {
    await _local.retryFailedMessage(messageId);
  }

  // ---------------------------------------------------------------------------
  // HELPERS PRIVADOS
  // ---------------------------------------------------------------------------

  /// Genera un ID de thread determinístico a partir de dos user IDs.
  ///
  /// IMPORTANTE: usar siempre el mismo algoritmo para garantizar que
  /// dos usuarios siempre obtengan el mismo thread ID sin importar
  /// quién inicia la conversación.
  ///
  /// Se ordenan los IDs alfabéticamente antes de generar el UUID v5
  /// para que sea idempotente: generateId(A, B) == generateId(B, A).
  String _generateThreadId(String userAId, String userBId) {
    final ids = [userAId, userBId]..sort();
    return const Uuid().v5(Namespace.url.value, '${ids[0]}-${ids[1]}');
  }

  /// Convierte el JSON del servidor a una [UserEntity].
  UserEntity _mapRemoteUser(Map<String, dynamic> json) => UserEntity(
    id: json['id'] as String,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}


/*
MessageStatus como enum con fromString() — la DB guarda strings ('pending', 'sent'), la UI consume el enum. 
El conversor vive en la entidad misma — no en el DAO ni en el BLoC.
_generateThreadId() determinístico — usa UUID v5 con los IDs ordenados alfabéticamente. 
generateId(A,B) == generateId(B,A) siempre. 
Esto evita que dos usuarios creen threads duplicados cuando ambos se escriben por primera vez "simultáneamente" en offline.
searchUsers() con estrategia local + remoto — los resultados locales son instantáneos. 
Los remotos llegan después y se cachean. El usuario ve algo de inmediato; los resultados se enriquecen si hay red. Sin bloqueos.
ChatLocalDs._mapThreadsWithParticipants() — Drift no hace JOINs automáticos entre tablas. 
Se resuelven los participantes manualmente con un loop. 
El fallback 'Usuario desconocido' evita crashes si por alguna razón el usuario no está cacheado aún.
*/