// DAO para la tabla Messages.
//
// Este es el DAO más activo del proyecto. Cada mensaje enviado o recibido
// pasa por aquí. Los métodos de actualización de status son llamados
// frecuentemente por el OutboxWorker conforme procesa la cola offline.
//
// FLUJO DE ESTADOS DE UN MENSAJE (desde la perspectiva del DAO):
//
//   insertMessage()          → status: 'pending', syncStatus: 'pending'
//        ↓ OutboxWorker envía al server exitosamente
//   markAsSent()             → status: 'sent',    syncStatus: 'synced'
//        ↓ OutboxWorker falla después de N reintentos
//   markAsFailed()           → status: 'failed',  syncStatus: 'pending'
//        ↓ Llega mensaje de otro usuario (WebSocket / delta sync)
//   insertMessage()          → status: 'received',syncStatus: 'synced'

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/messages_table.dart';

part 'messages_dao.g.dart';

/// DAO que encapsula todas las operaciones sobre la tabla [Messages].
@DriftAccessor(tables: [Messages])
class MessagesDao extends DatabaseAccessor<AppDatabase> with _$MessagesDaoMixin {
  MessagesDao(super.db);

  // ---------------------------------------------------------------------------
  // ESCRITURA
  // ---------------------------------------------------------------------------

  /// Inserta un nuevo mensaje en la base de datos local.
  ///
  /// Se usa para dos casos:
  ///   1. Mensaje enviado por el usuario → status: 'pending'
  ///   2. Mensaje recibido del servidor → status: 'received'
  ///
  /// [InsertMode.insertOrIgnore] previene duplicados cuando el delta sync
  /// descarga mensajes que el WebSocket ya había insertado.
  Future<void> insertMessage(MessagesCompanion message) =>
      into(messages).insert(message, mode: InsertMode.insertOrIgnore);

  /// Inserta múltiples mensajes en una sola transacción.
  ///
  /// Se usa en el delta sync cuando se reciben N mensajes nuevos
  /// del servidor al reconectar. Batch es significativamente más
  /// rápido que N inserciones individuales.
  Future<void> insertMessages(List<MessagesCompanion> messageList) =>
      batch((b) => b.insertAllOnConflictUpdate(messages, messageList));

  /// Marca un mensaje como enviado y confirmado por el servidor.
  ///
  /// El OutboxWorker llama este método cuando el servidor responde
  /// con 200/201 al request de envío del mensaje.
  /// La UI reacciona automáticamente vía el stream watchMessages()
  /// cambiando el ícono de ⏱ a ✓.
  Future<void> markAsSent(String messageId) => (update(messages)..where((m) => m.id.equals(messageId))).write(
    const MessagesCompanion(status: Value('sent'), syncStatus: Value('synced')),
  );

  /// Marca un mensaje como fallido después de N reintentos.
  ///
  /// El OutboxWorker llama este método cuando se agota el número
  /// máximo de reintentos. La UI muestra ✗ y puede ofrecer un
  /// botón de "Reintentar" al usuario.
  Future<void> markAsFailed(String messageId) =>
      (update(messages)..where((m) => m.id.equals(messageId))).write(const MessagesCompanion(status: Value('failed')));

  /// Resetea un mensaje fallido a pending para reintentarlo.
  ///
  /// Se usa cuando el usuario toca el botón "Reintentar" en un
  /// mensaje con status 'failed'. Vuelve a insertar en el outbox
  /// y cambia el status visual de vuelta a ⏱.
  Future<void> resetToPending(String messageId) => (update(messages)..where((m) => m.id.equals(messageId))).write(
    const MessagesCompanion(status: Value('pending'), syncStatus: Value('pending')),
  );

  // ---------------------------------------------------------------------------
  // LECTURA — Queries únicas (Future)
  // ---------------------------------------------------------------------------

  /// Obtiene el timestamp del mensaje más reciente de un thread.
  ///
  /// Se usa en el delta sync para saber desde cuándo pedir mensajes:
  ///   GET /messages/{threadId}?since={lastMessageAt}
  ///
  /// Si el thread no tiene mensajes locales, retorna null y el sync
  /// pedirá todos los mensajes del thread.
  Future<DateTime?> getLastMessageTimestamp(String threadId) async {
    final query = select(messages)
      ..where((m) => m.threadId.equals(threadId))
      ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
      ..limit(1);

    final result = await query.getSingleOrNull();
    return result?.createdAt;
  }

  /// Obtiene todos los mensajes pendientes de un thread.
  ///
  /// Se usa para mostrar en la UI cuántos mensajes no se han podido
  /// sincronizar (badge o indicador en la thread card).
  Future<List<Message>> getPendingMessages(String threadId) =>
      (select(messages)..where((m) => m.threadId.equals(threadId) & m.status.equals('pending'))).get();

  // ---------------------------------------------------------------------------
  // LECTURA — Streams reactivos (para BLoC)
  // ---------------------------------------------------------------------------

  /// Stream de todos los mensajes de un thread, ordenados cronológicamente.
  ///
  /// Es el stream principal del ChatBloc. Emite un nuevo valor cada vez
  /// que:
  ///   · Se inserta un mensaje nuevo (enviado o recibido)
  ///   · El status de un mensaje cambia (pending → sent, etc.)
  ///
  /// La UI no necesita lógica adicional: cada emisión del stream
  /// reconstruye la lista completa de mensajes con los estados actuales.
  ///
  /// ORDEN: createdAt ASC → los mensajes más antiguos arriba,
  /// los más nuevos abajo (convención estándar de chat).
  Stream<List<Message>> watchMessages(String threadId) =>
      (select(messages)
            ..where((m) => m.threadId.equals(threadId))
            ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
          .watch();

  /// Stream del conteo de mensajes pendientes en todos los threads.
  ///
  /// Permite mostrar un indicador global en ThreadsScreen cuando
  /// hay mensajes sin sincronizar (útil para debugging también).
  Stream<int> watchPendingCount() {
    final countExp = messages.id.count();
    final query = selectOnly(messages)
      ..addColumns([countExp])
      ..where(messages.status.equals('pending'));

    return query.map((row) => row.read(countExp) ?? 0).watchSingle();
  }
}
