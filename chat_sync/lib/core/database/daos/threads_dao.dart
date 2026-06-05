// DAO para la tabla Threads.
//
// Los threads son las conversaciones. Este DAO maneja tanto la creación
// local inmediata (offline-first) como las actualizaciones de metadata
// que ocurren cada vez que llega o se envía un mensaje nuevo.
//
// PATRÓN CLAVE — Desnormalización del último mensaje:
//   Cada vez que se inserta un mensaje, ThreadsDao.updateLastMessage()
//   se llama dentro de la misma transacción. Esto mantiene la lista
//   de threads siempre actualizada sin necesidad de JOINs costosos.

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/threads_table.dart';

part 'threads_dao.g.dart';

/// DAO que encapsula todas las operaciones sobre la tabla [Threads].
@DriftAccessor(tables: [Threads])
class ThreadsDao extends DatabaseAccessor<AppDatabase> with _$ThreadsDaoMixin {
  ThreadsDao(super.db);

  // ---------------------------------------------------------------------------
  // ESCRITURA
  // ---------------------------------------------------------------------------

  /// Inserta un nuevo thread localmente.
  ///
  /// Se llama cuando el usuario decide escribirle a alguien nuevo.
  /// El thread se crea con syncStatus 'pending' porque aún no existe
  /// en el servidor. El OutboxWorker se encarga de crearlo remotamente.
  ///
  /// [InsertMode.insertOrIgnore] evita errores si el thread ya existe
  /// (ej: el usuario toca dos veces el mismo contacto en búsqueda).
  Future<void> insertThread(ThreadsCompanion thread) => into(threads).insert(thread, mode: InsertMode.insertOrIgnore);

  /// Actualiza el último mensaje visible en la thread card.
  ///
  /// Se llama dentro de la misma transacción que inserta el mensaje,
  /// garantizando consistencia entre ambas tablas. Si falla uno, falla
  /// el otro (atomicidad).
  ///
  /// [lastMessage] texto del mensaje (puede truncarse en la UI).
  /// [lastMessageAt] timestamp para el ordenamiento de threads.
  Future<void> updateLastMessage({
    required String threadId,
    required String lastMessage,
    required DateTime lastMessageAt,
  }) => (update(threads)..where((t) => t.id.equals(threadId))).write(
    ThreadsCompanion(lastMessage: Value(lastMessage), lastMessageAt: Value(lastMessageAt)),
  );

  /// Marca un thread como sincronizado con el servidor.
  ///
  /// El OutboxWorker llama este método después de confirmar con el
  /// servidor que el thread fue creado exitosamente.
  Future<void> markAsSynced(String threadId) =>
      (update(threads)..where((t) => t.id.equals(threadId))).write(const ThreadsCompanion(syncStatus: Value('synced')));

  // ---------------------------------------------------------------------------
  // LECTURA — Queries únicas (Future)
  // ---------------------------------------------------------------------------

  /// Busca un thread existente entre el usuario actual y un participante.
  ///
  /// Se usa al abrir un chat: si ya existe el thread, se abre directamente.
  /// Si no existe, el Repository crea uno nuevo localmente.
  Future<Thread?> getThreadByParticipant(String participantId) =>
      (select(threads)..where((t) => t.participantId.equals(participantId))).getSingleOrNull();

  /// Obtiene un thread por su ID.
  Future<Thread?> getThreadById(String id) => (select(threads)..where((t) => t.id.equals(id))).getSingleOrNull();

  // ---------------------------------------------------------------------------
  // LECTURA — Streams reactivos (para BLoC)
  // ---------------------------------------------------------------------------

  /// Stream de todos los threads ordenados por actividad reciente.
  ///
  /// Emite un nuevo valor cada vez que cualquier thread cambia:
  /// nuevo mensaje, sync status actualizado, etc.
  ///
  /// El ThreadsBloc se suscribe a este stream en su constructor.
  /// Cada emisión del stream genera un nuevo estado ThreadsLoaded
  /// que reconstruye la lista en la UI automáticamente.
  ///
  /// ORDEN: lastMessageAt DESC → los más recientes primero.
  /// Los threads sin mensajes (null) van al final.
  Stream<List<Thread>> watchAllThreads() =>
      (select(threads)..orderBy([
            (t) => OrderingTerm(expression: t.lastMessageAt, mode: OrderingMode.desc, nulls: NullsOrder.last),
          ]))
          .watch();

  /// Stream de un thread específico.
  ///
  /// El ChatBloc lo usa para detectar cambios en el syncStatus del
  /// thread mientras el usuario está en la pantalla de chat.
  Stream<Thread?> watchThread(String threadId) =>
      (select(threads)..where((t) => t.id.equals(threadId))).watchSingleOrNull();
}
