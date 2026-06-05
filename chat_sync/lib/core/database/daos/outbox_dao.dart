// DAO para la tabla Outbox.
//
// A diferencia de los otros DAOs que principalmente leen datos para
// mostrarlos en la UI, este DAO es usado casi exclusivamente por el
// OutboxWorker — el componente que procesa la cola de operaciones
// pendientes en background.
//
// CICLO DE VIDA DE UNA ENTRADA EN EL OUTBOX:
//
//   1. insertOperation()     → nueva entrada, retries: 0
//   2. OutboxWorker la toma  → intenta HTTP request
//   3a. Éxito               → deleteOperation() — se elimina
//   3b. Fallo               → incrementRetries() — se reintenta luego
//   4.  retries >= maxRetries → OutboxWorker marca el mensaje como
//                              'failed' y elimina la entrada del outbox

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/outbox_table.dart';

part 'outbox_dao.g.dart';

/// DAO que encapsula todas las operaciones sobre la tabla [Outbox].
@DriftAccessor(tables: [Outbox])
class OutboxDao extends DatabaseAccessor<AppDatabase> with _$OutboxDaoMixin {
  OutboxDao(super.db);

  // ---------------------------------------------------------------------------
  // ESCRITURA
  // ---------------------------------------------------------------------------

  /// Inserta una nueva operación pendiente en el outbox.
  ///
  /// Este método SIEMPRE se llama dentro de una transacción junto con
  /// la inserción del dato principal (mensaje, thread). La atomicidad
  /// garantiza que si se guarda el mensaje, también se guarda en outbox,
  /// y viceversa. No puede existir un mensaje sin su entrada en outbox
  /// (ni al revés) en estado inconsistente.
  ///
  /// Ejemplo de uso en el Repository:
  /// ```dart
  /// await db.transaction(() async {
  ///   await messagesDao.insertMessage(messageCompanion);
  ///   await outboxDao.insertOperation(outboxCompanion);
  ///   await threadsDao.updateLastMessage(...);
  /// });
  /// ```
  Future<void> insertOperation(OutboxCompanion operation) => into(outbox).insert(operation);

  /// Incrementa el contador de reintentos de una operación fallida.
  ///
  /// Usa [customUpdate] con SQL directo para hacer retries = retries + 1
  /// en una sola operación atómica, evitando el read-modify-write
  /// que causaría race conditions si el worker corre en paralelo.
  Future<void> incrementRetries(int operationId) => customUpdate(
    'UPDATE outbox SET retries = retries + 1 WHERE id = ?',
    variables: [Variable.withInt(operationId)],
    updates: {outbox},
  );

  /// Elimina una operación completada exitosamente del outbox.
  ///
  /// Una entrada del outbox eliminada significa que la operación llegó
  /// al servidor y fue confirmada. El outbox debe mantenerse lo más
  /// limpio posible — entradas acumuladas indican problemas de sync.
  Future<void> deleteOperation(int operationId) => (delete(outbox)..where((o) => o.id.equals(operationId))).go();

  /// Elimina todas las operaciones del outbox (para testing/debugging).
  ///
  /// NO usar en producción salvo para limpiar estado corrupto.
  Future<void> clearOutbox() => delete(outbox).go();

  // ---------------------------------------------------------------------------
  // LECTURA — Queries únicas (Future)
  // ---------------------------------------------------------------------------

  /// Obtiene la siguiente operación pendiente a procesar.
  ///
  /// Siempre toma la más antigua (menor id) para preservar el orden FIFO.
  /// El OutboxWorker procesa de a una operación por vez para garantizar
  /// que los mensajes lleguen al servidor en el mismo orden en que
  /// el usuario los escribió.
  ///
  /// Retorna null si el outbox está vacío (nada que sincronizar).
  Future<OutboxData?> getNextPending() =>
      (select(outbox)
            ..orderBy([(o) => OrderingTerm.asc(o.id)])
            ..limit(1))
          .getSingleOrNull();

  /// Obtiene todas las operaciones pendientes.
  ///
  /// Se usa al iniciar el OutboxWorker para verificar si hay operaciones
  /// acumuladas de sesiones anteriores (mensajes escritos con la app
  /// cerrada... bueno, escritos antes de cerrar la app sin conexión).
  Future<List<OutboxData>> getAllPending() => (select(outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();

  /// Cuenta las operaciones pendientes en el outbox.
  ///
  /// Útil para mostrar badges o indicadores de sincronización en la UI.
  Future<int> getPendingCount() async {
    final countExp = outbox.id.count();
    final query = selectOnly(outbox)..addColumns([countExp]);
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // LECTURA — Streams reactivos (para OutboxWorker)
  // ---------------------------------------------------------------------------

  /// Stream que emite cuando hay operaciones pendientes en el outbox.
  ///
  /// El OutboxWorker se suscribe a este stream. Cada vez que se inserta
  /// una nueva operación (el usuario envía un mensaje), el stream emite
  /// y el worker intenta procesarla inmediatamente si hay red.
  ///
  /// Esto crea el ciclo de reactividad offline:
  ///   Usuario envía → insertOperation() → stream emite → worker procesa
  Stream<List<OutboxData>> watchPendingOperations() =>
      (select(outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).watch();
}
