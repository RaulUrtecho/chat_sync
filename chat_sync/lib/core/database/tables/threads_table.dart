// Tabla local de threads (conversaciones).
//
// Un thread representa la conversación entre el usuario actual y otro
// usuario. Almacena el último mensaje para mostrarlo en la lista de
// threads sin necesidad de hacer un JOIN con messages en cada render.
//
// DECISIÓN OFFLINE: los threads se crean localmente al instante cuando
// el usuario decide escribirle a alguien nuevo. Si no hay red, el thread
// existe localmente y el primer mensaje queda en el outbox. Al reconectar,
// el sync engine crea primero el thread en el server y luego los mensajes.

import 'package:drift/drift.dart';

import 'users_table.dart';

/// Definición de la tabla [Threads] para Drift.
class Threads extends Table {
  /// Identificador único del thread.
  ///
  /// UUID v4 generado en el cliente. El servidor usa este mismo ID,
  /// lo que garantiza que no hay conflictos ni necesidad de reasignación
  /// después de la sincronización.
  TextColumn get id => text()();

  /// Referencia al usuario participante (el contacto, no el usuario actual).
  ///
  /// Clave foránea hacia [Users]. En la UI se usa para mostrar el nombre
  /// del contacto en la thread card.
  ///
  /// NOTA: Drift no aplica FK constraints por default en SQLite.
  /// Se habilita con `PRAGMA foreign_keys = ON` en la configuración
  /// de la base de datos.
  TextColumn get participantId => text().references(Users, #id)();

  /// Contenido del último mensaje del thread.
  ///
  /// Se desnormaliza aquí para evitar un JOIN con [Messages] cada vez
  /// que se renderiza la lista de threads. Se actualiza cada vez que
  /// llega o se envía un nuevo mensaje.
  ///
  /// Nullable: un thread recién creado aún no tiene mensajes.
  TextColumn get lastMessage => text().nullable()();

  /// Timestamp del último mensaje.
  ///
  /// Se usa para ordenar los threads de más reciente a más antiguo
  /// en la lista principal. Nullable por la misma razón que lastMessage.
  DateTimeColumn get lastMessageAt => dateTime().nullable()();

  /// Estado de sincronización del thread con el servidor.
  ///
  /// Valores posibles (almacenados como String):
  ///   'pending' → creado localmente, aún no sincronizado con el server
  ///   'synced'  → confirmado por el servidor
  ///
  /// La UI puede usar este campo para mostrar indicadores visuales
  /// de threads que aún no se han podido crear en el servidor.
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();

  /// Timestamp de creación local del thread.
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
