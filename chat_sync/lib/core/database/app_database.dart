// Punto central de la base de datos local.
//
// Este archivo ensambla todas las tablas y DAOs de Drift en una sola
// clase [AppDatabase]. Es el único lugar donde Drift conoce la estructura
// completa del esquema local.
//
// RESPONSABILIDADES:
//   · Declarar todas las tablas del esquema
//   · Registrar todos los DAOs
//   · Configurar la conexión SQLite (nombre del archivo, opciones)
//   · Manejar migraciones de esquema entre versiones
//   · Habilitar foreign keys (desactivadas por default en SQLite)
//
// GENERACIÓN DE CÓDIGO:
//   Drift genera app_database.g.dart a partir de este archivo.
//   Cada vez que se modifiquen tablas o DAOs, ejecutar:
//     dart run build_runner build --delete-conflicting-outputs
//
// SINGLETON:
//   AppDatabase debe existir como una sola instancia en toda la app.
//   Se registra en el inyector de dependencias (get_it) como singleton.
//   Ver: lib/core/di/injector.dart

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import 'daos/messages_dao.dart';
import 'daos/outbox_dao.dart';
import 'daos/threads_dao.dart';
import 'daos/users_dao.dart';
import 'tables/messages_table.dart';
import 'tables/outbox_table.dart';
import 'tables/threads_table.dart';
import 'tables/users_table.dart';

// La anotación @DriftDatabase le dice a Drift qué tablas y DAOs incluir
// en la generación de código. El archivo generado será app_database.g.dart.
part 'app_database.g.dart';

/// Versión actual del esquema de la base de datos.
///
/// Se incrementa cada vez que se modifica la estructura de alguna tabla.
/// Drift usa este número para determinar si necesita ejecutar migraciones.
///
/// HISTORIAL:
///   v1 → Esquema inicial: users, threads, messages, outbox
const int _kSchemaVersion = 1;

/// Base de datos local principal de ChatSync.
///
/// Extiende [_$AppDatabase] que es generado por Drift a partir de
/// las anotaciones de este archivo.
///
/// USO:
/// ```dart
/// // Obtener la instancia desde el inyector
/// final db = getIt<AppDatabase>();
///
/// // Acceder a un DAO
/// final user = await db.usersDao.getCurrentUser();
///
/// // Ejecutar una transacción
/// await db.transaction(() async {
///   await db.messagesDao.insertMessage(msg);
///   await db.outboxDao.insertOperation(op);
/// });
/// ```
@DriftDatabase(tables: [Users, Threads, Messages, Outbox], daos: [UsersDao, ThreadsDao, MessagesDao, OutboxDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // ---------------------------------------------------------------------------
  // VERSIÓN Y MIGRACIONES
  // ---------------------------------------------------------------------------

  /// Versión actual del esquema.
  ///
  /// Drift compara este valor con el almacenado en la DB al abrirla.
  /// Si el valor nuevo es mayor, ejecuta [migration].
  @override
  int get schemaVersion => _kSchemaVersion;

  /// Estrategia de migración entre versiones del esquema.
  ///
  /// [onCreate]: se ejecuta la primera vez que se crea la base de datos
  ///   (instalación nueva de la app). Crea todas las tablas.
  ///
  /// [onUpgrade]: se ejecuta cuando [schemaVersion] aumenta.
  ///   Aquí se agregan columnas, crean tablas nuevas, etc.
  ///   NUNCA eliminar datos en una migración de producción sin
  ///   ofrecer al usuario la opción de respaldar primero.
  ///
  /// [beforeOpen]: se ejecuta cada vez que se abre la DB, antes de
  ///   cualquier query. Es el lugar correcto para habilitar PRAGMAs
  ///   de SQLite como foreign_keys.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    // Primera instalación: crear todas las tablas
    onCreate: (m) async {
      await m.createAll();
    },

    // Actualizaciones de esquema
    onUpgrade: (m, from, to) async {
      // Ejemplo de migración futura (versión 1 → 2):
      // if (from < 2) {
      //   await m.addColumn(messages, messages.editedAt);
      // }
      //
      // Ejemplo de migración versión 2 → 3:
      // if (from < 3) {
      //   await m.createTable(reactions);
      // }
    },

    // Se ejecuta antes de cada apertura de la DB
    beforeOpen: (details) async {
      // CRÍTICO: habilitar foreign key constraints en SQLite.
      // Por default SQLite ignora las claves foráneas.
      // Con este PRAGMA, un insert con un threadId inexistente
      // en messages lanzará un error en lugar de insertarse
      // silenciosamente con una referencia rota.
      await customStatement('PRAGMA foreign_keys = ON');

      // WAL (Write-Ahead Logging): modo de journaling más eficiente
      // para apps móviles. Permite lecturas concurrentes mientras
      // se escribe, lo que mejora la fluidez de la UI cuando el
      // OutboxWorker escribe en background.
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );

  // ---------------------------------------------------------------------------
  // HELPERS DE TRANSACCIÓN
  // ---------------------------------------------------------------------------

  /// Guarda un mensaje y su operación de outbox en una sola transacción.
  ///
  /// Este es el método más importante del proyecto para la consistencia
  /// offline. Al ejecutar ambas operaciones en la misma transacción:
  ///   · Si falla el insert del mensaje → outbox no se toca
  ///   · Si falla el insert del outbox → mensaje no se guarda
  ///
  /// Nunca puede quedar un mensaje sin su entrada en outbox, ni
  /// una entrada de outbox sin su mensaje correspondiente.
  ///
  /// [messageCompanion] datos del mensaje a insertar.
  /// [outboxCompanion] operación correspondiente para el outbox.
  /// [threadId] thread al que pertenece (para actualizar lastMessage).
  /// [content] contenido del mensaje (para desnormalizar en thread).
  /// [sentAt] timestamp del mensaje.
  Future<void> saveMessageWithOutbox({
    required MessagesCompanion messageCompanion,
    required OutboxCompanion outboxCompanion,
    required String threadId,
    required String content,
    required DateTime sentAt,
  }) => transaction(() async {
    // 1. Insertar el mensaje en su tabla
    await messagesDao.insertMessage(messageCompanion);

    // 2. Registrar la operación en el outbox para sync posterior
    await outboxDao.insertOperation(outboxCompanion);

    // 3. Actualizar el último mensaje del thread (desnormalización)
    //    para que la thread card muestre el texto correcto sin JOIN
    await threadsDao.updateLastMessage(threadId: threadId, lastMessage: content, lastMessageAt: sentAt);
  });

  /// Crea un thread y registra su operación de outbox atómicamente.
  ///
  /// Se usa cuando el usuario abre un chat con alguien nuevo.
  /// El thread se crea localmente de inmediato; el outbox lo sincroniza
  /// con el servidor cuando haya conexión.
  Future<void> saveThreadWithOutbox({
    required ThreadsCompanion threadCompanion,
    required OutboxCompanion outboxCompanion,
  }) => transaction(() async {
    await threadsDao.insertThread(threadCompanion);
    await outboxDao.insertOperation(outboxCompanion);
  });
}

// ---------------------------------------------------------------------------
// CONFIGURACIÓN DE LA CONEXIÓN SQLITE
// ---------------------------------------------------------------------------

/// Crea y configura la conexión a la base de datos SQLite.
///
/// Usa [driftDatabase] de drift_flutter — wrapper de alto nivel que
/// selecciona automáticamente la implementación correcta por plataforma:
///   · Android/iOS → sqlite3 nativo (sqlite3_flutter_libs)
///   · macOS/Linux → sqlite3 del sistema
///   · Windows     → sqlite3_flutter_libs
///   · Web         → sqlite3 WASM (requiere sqlite3.wasm + drift_worker.js en web/)
///
/// El archivo 'chat_sync.db' se crea automáticamente en el directorio
/// de datos de la app (Application Documents Directory en iOS/Android).
///
/// NOTA: [driftDatabase] no expone el objeto sqlite3.Database subyacente,
/// por lo que los PRAGMAs de [migration.beforeOpen] se aplican a través
/// de [customStatement] en lugar del callback [setup].
///
/// Si en el futuro se requiere encriptación (SQLCipher) o mayor control
/// sobre la apertura, reemplazar por [LazyDatabase] + [NativeDatabase.createInBackground]:
/// ```dart
/// return LazyDatabase(() async {
///   final dir = await getApplicationDocumentsDirectory();
///   final file = File(p.join(dir.path, 'chat_sync.db'));
///   return NativeDatabase.createInBackground(
///     file,
///     setup: (db) => db.execute("PRAGMA key = 'secreto'"),
///   );
/// });
/// ```
QueryExecutor _openConnection() {
  if (kIsWeb) {
    return driftDatabase(name: 'chat_sync');
  }

  // LazyDatabase resuelve el Future<File> antes de abrir la conexión
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'chat_sync.db'));

    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA foreign_keys = ON');
      },
    );
  });
}

/*
Tres decisiones importantes documentadas en el archivo:
PRAGMA foreign_keys = ON — SQLite ignora las claves foráneas por default. 
Sin este PRAGMA, podrías insertar un mensaje con un threadId que no existe y SQLite no reclamaría nada. 
Se activa en beforeOpen para que aplique en cada apertura de la DB.
PRAGMA journal_mode = WAL — Write-Ahead Logging permite que el OutboxWorker escriba en background 
mientras la UI lee concurrentemente sin bloquearse. En el modo default (DELETE journal), una escritura bloquea todas las lecturas.
saveMessageWithOutbox() — el helper de transacción más crítico del proyecto. 
Ejecuta en una sola transacción atómica: insert del mensaje + insert en outbox + update del lastMessage del thread. 
Si cualquiera de los tres falla, los tres se revierten. Nunca puede existir inconsistencia entre las tablas.
Migraciones — el patrón con if (from < N) permite que un usuario que saltó de v1 a v3 directamente ejecute todas las migraciones intermedias en orden.
*/
