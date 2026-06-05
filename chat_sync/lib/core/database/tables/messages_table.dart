// Tabla local de mensajes.
//
// Es la tabla más importante del proyecto desde la perspectiva offline.
// Cada mensaje tiene un [status] que refleja su ciclo de vida completo:
// desde que el usuario lo escribe hasta que el servidor lo confirma.
//
// CICLO DE VIDA DE UN MENSAJE:
//
//   1. Usuario envía mensaje
//      → status: 'pending', syncStatus: 'pending'
//      → se inserta en outbox simultáneamente
//
//   2a. OutboxWorker lo envía exitosamente al servidor
//       → status: 'sent', syncStatus: 'synced'
//
//   2b. OutboxWorker falla después de N reintentos
//       → status: 'failed', syncStatus: 'pending'
//       → el usuario puede ver el error y reintentar manualmente
//
//   3. Mensaje recibido de otro usuario (vía WebSocket o delta sync)
//      → status: 'received', syncStatus: 'synced'

import 'package:drift/drift.dart';

import 'threads_table.dart';
import 'users_table.dart';

/// Definición de la tabla [Messages] para Drift.
class Messages extends Table {
  /// Identificador único del mensaje.
  ///
  /// UUID v4 generado en el cliente ANTES de enviarlo al servidor.
  /// Este mismo UUID se usa como idempotency key en el outbox.
  /// Si el servidor recibe el mismo UUID dos veces (por retry), lo ignora.
  TextColumn get id => text()();

  /// Thread al que pertenece este mensaje.
  ///
  /// Clave foránea hacia [Threads].
  TextColumn get threadId => text().references(Threads, #id)();

  /// Usuario que envió el mensaje.
  ///
  /// Clave foránea hacia [Users]. Puede ser el usuario actual o el contacto.
  /// La UI usa este campo para decidir si la burbuja va a la derecha (yo)
  /// o a la izquierda (contacto).
  TextColumn get senderId => text().references(Users, #id)();

  /// Contenido de texto del mensaje.
  ///
  /// En este proyecto solo manejamos texto plano. En una app real
  /// aquí también habría tipo (imagen, audio, sticker) y una URL/path.
  TextColumn get content => text()();

  /// Estado del mensaje en su ciclo de vida offline.
  ///
  /// Valores posibles:
  ///   'pending'  → guardado local, esperando sync (muestra ⏱ en UI)
  ///   'sent'     → confirmado por el servidor (muestra ✓ en UI)
  ///   'failed'   → falló tras N reintentos (muestra ✗ en UI)
  ///   'received' → mensaje de otro usuario, ya sincronizado
  ///
  /// Solo los mensajes enviados por el usuario actual tienen estados
  /// pending/sent/failed. Los mensajes recibidos siempre son 'received'.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// Estado de sincronización con el servidor.
  ///
  /// Valores posibles:
  ///   'pending' → aún no confirmado por el servidor
  ///   'synced'  → el servidor lo conoce
  ///
  /// Es diferente de [status]: un mensaje puede estar 'sent' pero si
  /// el ACK del servidor se perdió, syncStatus puede ser 'pending'
  /// hasta la próxima verificación.
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();

  /// Timestamp de creación del mensaje.
  ///
  /// Generado en el cliente al momento de escribir el mensaje.
  /// El servidor puede tener un timestamp ligeramente diferente
  /// por latencia, pero para ordenación visual se usa el del cliente.
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
