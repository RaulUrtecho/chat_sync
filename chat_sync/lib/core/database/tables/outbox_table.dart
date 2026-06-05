// Tabla del Outbox — el corazón del soporte offline.
//
// El Outbox Pattern es el mecanismo fundamental que garantiza que ninguna
// acción del usuario se pierda, sin importar el estado de la red.
//
// CÓMO FUNCIONA:
//
//   Toda operación que requiere sincronización con el servidor se registra
//   aquí ANTES de intentar la llamada HTTP. El OutboxWorker procesa esta
//   cola en orden cuando hay conexión disponible.
//
//   ESCRITURA (Repository):
//     1. Escribe el dato en su tabla principal (messages, threads, etc.)
//     2. Inserta una entrada en outbox con la operación a realizar
//     3. Retorna inmediatamente → UI se actualiza sin esperar red
//
//   PROCESAMIENTO (OutboxWorker):
//     1. Observa la tabla outbox con un Stream de Drift
//     2. Cuando hay entradas pendientes Y hay red, las procesa en orden
//     3. Si la operación HTTP es exitosa → elimina la entrada del outbox
//     4. Si falla → incrementa [retries] y espera con backoff exponencial
//     5. Si [retries] >= maxRetries → marca el mensaje como 'failed'
//
// GARANTÍAS:
//   · Orden preservado: createdAt ASC garantiza FIFO
//   · Sin duplicados: idempotencyKey previene duplicados en el servidor
//   · Durabilidad: sobrevive al cierre de la app (está en SQLite)
//   · Atomicidad: la inserción en la tabla principal y en outbox
//     ocurre en la misma transacción SQLite

import 'package:drift/drift.dart';

/// Tipos de operaciones que pueden estar en el outbox.
///
/// Se almacenan como String en la base de datos.
/// Se definen como constantes aquí para evitar magic strings.
class OutboxOperationType {
  /// Enviar un nuevo mensaje al servidor.
  static const String sendMessage = 'send_message';

  /// Crear un nuevo thread en el servidor.
  static const String createThread = 'create_thread';

  /// Registrar un nuevo usuario en el servidor.
  static const String createUser = 'create_user';
}

/// Definición de la tabla [Outbox] para Drift.
///
/// Esta tabla actúa como una cola durable de operaciones pendientes.
/// A diferencia de las otras tablas, los registros del outbox son
/// TEMPORALES: se eliminan una vez que la operación se completa
/// exitosamente en el servidor.
class Outbox extends Table {
  /// Identificador único de la entrada del outbox.
  ///
  /// Autoincremental para garantizar orden de inserción FIFO.
  /// El OutboxWorker procesa las entradas de menor a mayor id.
  IntColumn get id => integer().autoIncrement()();

  /// Tipo de operación a realizar en el servidor.
  ///
  /// Ver [OutboxOperationType] para los valores posibles.
  /// El OutboxWorker usa este campo para saber qué endpoint llamar
  /// y cómo deserializar el [payload].
  TextColumn get operationType => text()();

  /// Datos de la operación serializados como JSON.
  ///
  /// Ejemplos:
  ///   send_message:  {"id":"uuid","threadId":"uuid","content":"Hola","senderId":"uuid"}
  ///   create_thread: {"id":"uuid","participantId":"uuid"}
  ///   create_user:   {"id":"uuid","name":"Juan"}
  ///
  /// El OutboxWorker deserializa este JSON según el [operationType]
  /// y construye el body del request HTTP.
  TextColumn get payload => text()();

  /// Número de intentos fallidos para esta operación.
  ///
  /// Empieza en 0. El OutboxWorker incrementa este valor después de
  /// cada fallo. Se usa para calcular el delay del backoff exponencial:
  ///   delay = min(2^retries segundos, maxDelay)
  ///   retries=0 → 1s, retries=1 → 2s, retries=2 → 4s, retries=3 → 8s
  ///
  /// Cuando [retries] >= maxRetries, la operación se considera fallida
  /// y se actualiza el status del mensaje/thread correspondiente.
  IntColumn get retries => integer().withDefault(const Constant(0))();

  /// Clave de idempotencia para prevenir duplicados en el servidor.
  ///
  /// Es el mismo UUID que el id del recurso creado (mensaje, thread).
  /// Se envía como header HTTP: X-Idempotency-Key.
  ///
  /// PROBLEMA QUE RESUELVE: si el servidor procesa la operación pero
  /// el ACK se pierde en la red (timeout), el cliente la reintentará.
  /// Sin idempotency key, el servidor crearía el recurso dos veces.
  /// Con idempotency key, el servidor reconoce el retry y responde 200
  /// sin crear un duplicado.
  TextColumn get idempotencyKey => text()();

  /// Timestamp de inserción en el outbox.
  ///
  /// Se usa para dos propósitos:
  ///   1. Ordenar operaciones FIFO junto con [id]
  ///   2. Detectar operaciones muy antiguas que nunca se procesaron
  ///      (posible señal de un bug en el worker)
  DateTimeColumn get createdAt => dateTime()();
}
