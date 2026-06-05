// ChatLocalDs — Data source local.
//
// Capa de acceso a los DAOs de Drift. Convierte entre los tipos de Drift
// (DataClasses generadas) y las entidades de dominio que usan los BLoCs.
//
// RESPONSABILIDAD:
//   · Abstraer los detalles de Drift del Repository
//   · Convertir Drift DataClasses → Entidades de dominio
//   · Exponer streams y futures tipados con entidades de dominio
//
// NOTA SOBRE LA CONVERSIÓN:
//   Drift genera clases como User, Thread, Message (DataClasses).
//   Nosotros usamos UserEntity, ThreadEntity, MessageEntity (dominio).
//   La conversión ocurre aquí — el Repository solo ve entidades.

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/message_entity.dart';
import '../../domain/entities/thread_entity.dart';
import '../../domain/entities/user_entity.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/tables/outbox_table.dart';

/// Data source local que abstrae los DAOs de Drift.
class ChatLocalDs {
  ChatLocalDs({required AppDatabase database, required SharedPreferences sharedPreferences})
    : _db = database,
      _prefs = sharedPreferences;

  final AppDatabase _db;
  final SharedPreferences _prefs;

  String? get _currentUserId => _prefs.getString('current_user_id');

  // ---------------------------------------------------------------------------
  // USUARIOS
  // ---------------------------------------------------------------------------

  /// Guarda el usuario actual en la DB local y en SharedPreferences.
  ///
  /// SharedPreferences almacena el ID para acceso rápido en el
  /// AuthInterceptor sin necesidad de abrir la DB.
  Future<void> saveCurrentUser(UserEntity user) async {
    await _db.usersDao.insertUser(
      UsersCompanion(
        id: Value(user.id),
        name: Value(user.name),
        isCurrentUser: const Value(true),
        createdAt: Value(user.createdAt),
      ),
    );
    await _prefs.setString('current_user_id', user.id);
    await _prefs.setString('current_user_name', user.name);
  }

  /// Obtiene el usuario actual desde la DB local.
  Future<UserEntity?> getCurrentUser() async {
    final user = await _db.usersDao.getCurrentUser();
    return user != null ? _mapUser(user) : null;
  }

  /// Stream del usuario actual — emite cuando cambian sus datos.
  Stream<UserEntity?> watchCurrentUser() {
    return _db.usersDao.watchCurrentUser().map((user) => user != null ? _mapUser(user) : null);
  }

  /// Guarda un contacto (usuario encontrado en búsqueda) localmente.
  ///
  /// Se persiste para que su nombre esté disponible offline en los threads.
  Future<void> cacheUser(UserEntity user) async {
    await _db.usersDao.insertUser(
      UsersCompanion(
        id: Value(user.id),
        name: Value(user.name),
        isCurrentUser: const Value(false),
        createdAt: Value(user.createdAt),
      ),
    );
  }

  /// Guarda múltiples contactos en una sola transacción.
  Future<void> cacheUsers(List<UserEntity> users) async {
    final companions = users
        .map(
          (u) => UsersCompanion(
            id: Value(u.id),
            name: Value(u.name),
            isCurrentUser: const Value(false),
            createdAt: Value(u.createdAt),
          ),
        )
        .toList();
    await _db.usersDao.insertUsers(companions);
  }

  /// Busca usuarios localmente por nombre (búsqueda offline).
  Future<List<UserEntity>> searchUsersLocally(String query) async {
    final users = await _db.usersDao.searchUsers(query);
    return users.map(_mapUser).toList();
  }

  // ---------------------------------------------------------------------------
  // THREADS
  // ---------------------------------------------------------------------------

  /// Stream de todos los threads con sus participantes.
  ///
  /// Emite cada vez que cualquier thread cambia (nuevo mensaje,
  /// sync status actualizado, etc.). El ThreadsBloc escucha este stream.
  Stream<List<ThreadEntity>> watchThreads() {
    // Drift no hace JOINs automáticos — necesitamos combinar
    // el stream de threads con los datos de los usuarios participantes.
    // Usamos switchMap: cada vez que cambian los threads, buscamos
    // los usuarios correspondientes.
    return _db.threadsDao.watchAllThreads().asyncMap((threads) => _mapThreadsWithParticipants(threads));
  }

  /// Obtiene un usuario por ID desde la DB local.
  Future<UserEntity?> getUserById(String id) async {
    final user = await _db.usersDao.getUserById(id);
    return user != null ? _mapUser(user) : null;
  }

  /// Busca o crea un thread con un participante dado.
  ///
  /// [syncStatus] permite forzar 'synced' cuando el thread viene del servidor
  /// (fetchAndCacheThreads) para no re-encolarlo en el outbox innecesariamente.
  Future<ThreadEntity> getOrCreateThread({
    required String threadId,
    required UserEntity participant,
    required String currentUserId,
    String syncStatus = 'pending',
  }) async {
    // Verificar si ya existe
    final existing = await _db.threadsDao.getThreadByParticipant(participant.id);

    if (existing != null) {
      return ThreadEntity(
        id: existing.id,
        participant: participant,
        lastMessage: existing.lastMessage,
        lastMessageAt: existing.lastMessageAt,
        syncStatus: existing.syncStatus,
        createdAt: existing.createdAt,
      );
    }

    // Crear el thread localmente
    final now = DateTime.now().toUtc();

    if (syncStatus == 'synced') {
      // Thread viene del servidor — solo persistir localmente sin outbox
      await _db.threadsDao.insertThread(
        ThreadsCompanion(
          id: Value(threadId),
          participantId: Value(participant.id),
          syncStatus: const Value('synced'),
          createdAt: Value(now),
        ),
      );
    } else {
      // Thread nuevo creado por el usuario — registrar en outbox para sync
      await _db.saveThreadWithOutbox(
        threadCompanion: ThreadsCompanion(
          id: Value(threadId),
          participantId: Value(participant.id),
          syncStatus: const Value('pending'),
          createdAt: Value(now),
        ),
        outboxCompanion: OutboxCompanion(
          operationType: const Value(OutboxOperationType.createThread),
          payload: Value('{"id":"$threadId","user_a_id":"$currentUserId","user_b_id":"${participant.id}"}'),
          idempotencyKey: Value(threadId),
          createdAt: Value(now),
        ),
      );
    }

    return ThreadEntity(id: threadId, participant: participant, syncStatus: syncStatus, createdAt: now);
  }

  // ---------------------------------------------------------------------------
  // MENSAJES
  // ---------------------------------------------------------------------------

  /// Stream de mensajes de un thread — el stream principal del ChatBloc.
  ///
  /// Emite cada vez que un mensaje cambia: nuevo mensaje insertado,
  /// status actualizado (pending → sent → failed), mensaje recibido.
  /// La UI se reconstruye automáticamente con cada emisión.
  Stream<List<MessageEntity>> watchMessages(String threadId) {
    final currentUserId = _currentUserId ?? '';
    return _db.messagesDao
        .watchMessages(threadId)
        .map((messages) => messages.map((m) => _mapMessage(m, currentUserId: currentUserId)).toList());
  }

  /// Guarda un mensaje nuevo localmente + lo encola en el outbox.
  ///
  /// Esta es la operación atómica más importante del proyecto:
  ///   1. Insertar mensaje con status 'pending'
  ///   2. Insertar operación en outbox
  ///   3. Actualizar lastMessage del thread
  ///
  /// Todo en una sola transacción SQLite. Si cualquier parte falla,
  /// ninguna ocurre.
  Future<void> saveMessageWithOutbox(MessageEntity message) async {
    final now = message.createdAt;
    await _db.saveMessageWithOutbox(
      messageCompanion: MessagesCompanion(
        id: Value(message.id),
        threadId: Value(message.threadId),
        senderId: Value(message.senderId),
        content: Value(message.content),
        status: const Value('pending'),
        syncStatus: const Value('pending'),
        createdAt: Value(now),
      ),
      outboxCompanion: OutboxCompanion(
        operationType: const Value(OutboxOperationType.sendMessage),
        payload: Value(
          '{"id":"${message.id}",'
          '"thread_id":"${message.threadId}",'
          '"sender_id":"${message.senderId}",'
          '"content":"${message.content}",'
          '"created_at":"${now.toIso8601String()}"}',
        ),
        idempotencyKey: Value(message.id),
        createdAt: Value(now),
      ),
      threadId: message.threadId,
      content: message.content,
      sentAt: now,
    );
  }

  /// Resetea un mensaje fallido a 'pending' y lo re-encola en el outbox.
  ///
  /// Operación atómica:
  ///   1. Cambia status del mensaje: 'failed' → 'pending'
  ///   2. Re-inserta en outbox con el mismo idempotencyKey (UUID del mensaje)
  ///
  /// El OutboxWorker lo procesará en el próximo ciclo si hay conexión.
  /// Drift emitirá el cambio en watchMessages() automáticamente.
  Future<void> retryFailedMessage(String messageId) async {
    // Resetear status en la tabla de mensajes
    await _db.messagesDao.resetToPending(messageId);

    // Recuperar el mensaje para reconstruir el payload del outbox
    final results = await (_db.select(_db.messages)..where((m) => m.id.equals(messageId))).get();

    if (results.isEmpty) return;
    final msg = results.first;

    // Re-insertar en outbox con el mismo idempotencyKey.
    // El servidor lo reconocerá como el mismo mensaje por el UUID
    // y no creará un duplicado.
    await _db.outboxDao.insertOperation(
      OutboxCompanion(
        operationType: const Value(OutboxOperationType.sendMessage),
        payload: Value(
          '{"id":"${msg.id}",'
          '"thread_id":"${msg.threadId}",'
          '"sender_id":"${msg.senderId}",'
          '"content":"${msg.content}",'
          '"created_at":"${msg.createdAt.toIso8601String()}"}',
        ),
        idempotencyKey: Value(msg.id),
        createdAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CONVERSORES — Drift DataClass → Entidad de dominio
  // ---------------------------------------------------------------------------

  /// Convierte un [User] de Drift a [UserEntity] de dominio.
  UserEntity _mapUser(User user) =>
      UserEntity(id: user.id, name: user.name, isCurrentUser: user.isCurrentUser, createdAt: user.createdAt);

  /// Convierte un [Message] de Drift a [MessageEntity] de dominio.
  MessageEntity _mapMessage(Message message, {required String currentUserId}) => MessageEntity(
    id: message.id,
    threadId: message.threadId,
    senderId: message.senderId,
    content: message.content,
    status: MessageStatus.fromString(message.status),
    createdAt: message.createdAt,
    isFromCurrentUser: message.senderId == currentUserId,
  );

  /// Convierte una lista de [Thread] de Drift a [ThreadEntity] de dominio,
  /// resolviendo los participantes desde la tabla de usuarios local.
  Future<List<ThreadEntity>> _mapThreadsWithParticipants(List<Thread> threads) async {
    final entities = <ThreadEntity>[];

    for (final thread in threads) {
      // Buscar el participante localmente — siempre debería existir
      // porque se cachea al momento de buscar/recibir el primer mensaje
      final participantRow = await _db.usersDao.getUserById(thread.participantId);

      final participant = participantRow != null
          ? _mapUser(participantRow)
          : UserEntity(id: thread.participantId, name: 'Usuario desconocido', createdAt: thread.createdAt);

      entities.add(
        ThreadEntity(
          id: thread.id,
          participant: participant,
          lastMessage: thread.lastMessage,
          lastMessageAt: thread.lastMessageAt,
          syncStatus: thread.syncStatus,
          createdAt: thread.createdAt,
        ),
      );
    }

    return entities;
  }
}
