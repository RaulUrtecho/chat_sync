// Tabla local de usuarios.
//
// Almacena tanto al usuario actual del dispositivo como a todos los
// contactos con los que se ha interactuado o buscado. Esto permite
// mostrar nombres en los threads y en el chat sin necesidad de red.
//
// DECISIÓN OFFLINE: los usuarios se cachean localmente en el momento
// en que se los busca o se recibe un mensaje de ellos. Así, aunque
// no haya red, los nombres siempre están disponibles en la UI.

import 'package:drift/drift.dart';

/// Definición de la tabla [Users] para Drift.
///
/// Drift usa esta clase para generar:
/// - La clase de datos `User` (DataClass inmutable)
/// - El companion `UsersCompanion` para inserciones y updates
/// - Los métodos tipados en el DAO correspondiente
class Users extends Table {
  /// Identificador único del usuario.
  ///
  /// UUID v4 generado en el cliente al momento del registro.
  /// Usar UUIDs del cliente (en lugar de auto-increment del server)
  /// es fundamental para el offline-first: permite crear registros
  /// locales con ID final sin esperar respuesta del servidor.
  TextColumn get id => text()();

  /// Nombre visible del usuario en la UI.
  ///
  /// Es el único dato de identidad que manejamos en este proyecto.
  /// No hay email, password ni datos adicionales de perfil.
  TextColumn get name => text().withLength(min: 1, max: 50)();

  /// Marca si este registro corresponde al usuario del dispositivo.
  ///
  /// Solo un registro puede tener isCurrentUser = true.
  /// Se usa para identificar el usuario local sin necesidad de
  /// consultar SharedPreferences en cada operación.
  BoolColumn get isCurrentUser => boolean().withDefault(const Constant(false))();

  /// Timestamp de creación del usuario en el sistema.
  ///
  /// Se almacena en UTC. Se usa en el delta sync para pedir solo
  /// los usuarios creados después de la última sincronización.
  DateTimeColumn get createdAt => dateTime()();

  /// Clave primaria: el id UUID.
  ///
  /// Drift necesita esta declaración explícita cuando la PK no
  /// es una columna auto-incremental (IntColumn con autoIncrement).
  @override
  Set<Column> get primaryKey => {id};
}
