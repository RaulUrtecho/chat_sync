// DAO (Data Access Object) para la tabla Users.
//
// Centraliza todas las queries relacionadas con usuarios. Los BLoCs
// nunca acceden directamente a las tablas de Drift — siempre pasan
// por el DAO correspondiente. Esto mantiene las queries tipadas y
// testeables de forma aislada.
//
// PATRÓN DE ACCESO:
//   BLoC → Repository → DAO → Drift (SQLite)

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/users_table.dart';

part 'users_dao.g.dart';

/// DAO que encapsula todas las operaciones de lectura y escritura
/// sobre la tabla [Users].
///
/// Se declara como parte de [AppDatabase] mediante la anotación
/// @DriftAccessor. Drift genera el código en app_database.g.dart.
@DriftAccessor(tables: [Users])
class UsersDao extends DatabaseAccessor<AppDatabase> with _$UsersDaoMixin {
  UsersDao(super.db);

  // ---------------------------------------------------------------------------
  // ESCRITURA
  // ---------------------------------------------------------------------------

  /// Inserta un nuevo usuario en la base de datos local.
  ///
  /// Usa [InsertMode.insertOrReplace] para que si el usuario ya existe
  /// (mismo id), se actualice con los datos más recientes. Esto es útil
  /// cuando el servidor devuelve datos actualizados de un usuario conocido.
  Future<void> insertUser(UsersCompanion user) => into(users).insert(user, mode: InsertMode.insertOrReplace);

  /// Inserta múltiples usuarios en una sola transacción.
  ///
  /// Se usa durante el delta sync cuando el servidor devuelve una lista
  /// de usuarios nuevos o actualizados. Una sola transacción es mucho
  /// más eficiente que N inserciones individuales.
  Future<void> insertUsers(List<UsersCompanion> userList) => batch((b) => b.insertAllOnConflictUpdate(users, userList));

  // ---------------------------------------------------------------------------
  // LECTURA — Queries únicas (Future)
  // ---------------------------------------------------------------------------

  /// Obtiene el usuario actual del dispositivo.
  ///
  /// Retorna null si aún no se ha creado el usuario (primera vez que
  /// se abre la app). El UserBloc usa este valor para decidir si
  /// mostrar CreateUserScreen o ThreadsScreen.
  Future<User?> getCurrentUser() => (select(users)..where((u) => u.isCurrentUser.equals(true))).getSingleOrNull();

  /// Busca un usuario por su ID.
  ///
  /// Retorna null si el usuario no existe localmente. En ese caso,
  /// el Repository debe buscarlo en el servidor y cachearlo.
  Future<User?> getUserById(String id) => (select(users)..where((u) => u.id.equals(id))).getSingleOrNull();

  /// Busca usuarios cuyo nombre contenga [query] (case-insensitive).
  ///
  /// Se usa en el search bar de ThreadsScreen. La búsqueda se hace
  /// primero localmente (instantánea) y en paralelo se consulta el
  /// servidor para resultados más completos.
  ///
  /// NOTA: '%$query%' es un patrón LIKE de SQL.
  ///   % → cualquier secuencia de caracteres
  ///   Ej: query='ju' encuentra 'Juan', 'Julio', 'Adjunto'
  Future<List<User>> searchUsers(String query) =>
      (select(users)
            ..where((u) => u.name.like('%$query%'))
            ..orderBy([(u) => OrderingTerm.asc(u.name)]))
          .get();

  // ---------------------------------------------------------------------------
  // LECTURA — Streams reactivos (para BLoC)
  // ---------------------------------------------------------------------------

  /// Stream del usuario actual.
  ///
  /// Emite un nuevo valor cada vez que los datos del usuario actual
  /// cambian en la base de datos. El UserBloc se suscribe a este stream
  /// para reaccionar automáticamente a cambios de sesión.
  Stream<User?> watchCurrentUser() => (select(users)..where((u) => u.isCurrentUser.equals(true))).watchSingleOrNull();
}
