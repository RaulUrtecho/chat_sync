// Inyector de dependencias — ensamble completo con get_it.
//
// RESPONSABILIDAD:
//   Crear y conectar todas las instancias de la app en el orden correcto.
//   Este archivo es el único lugar donde se instancian los objetos
//   de infraestructura. El resto de la app los consume sin saber
//   cómo fueron creados.
//
// PATRÓN SERVICE LOCATOR:
//   get_it actúa como un registro global de instancias. Cualquier
//   parte de la app puede obtener una dependencia con:
//     getIt<AppDatabase>()
//     getIt<ChatRepository>()
//     getIt<ConnectivityMonitor>()
//
//   Esto evita pasar dependencias por constructor a través de múltiples
//   capas (prop drilling) y simplifica la creación de BLoCs.
//
// TIPOS DE REGISTRO EN GET_IT:
//
//   registerSingleton → una sola instancia, creada inmediatamente.
//     Úsalo para objetos que deben existir desde el inicio de la app
//     y que otros objetos necesitan en su constructor.
//     Ej: AppDatabase, SharedPreferences, ConnectivityMonitor
//
//   registerLazySingleton → una sola instancia, creada la primera vez
//     que se solicita. Úsalo para objetos que pueden no ser necesarios
//     en todas las sesiones.
//     Ej: ChatRepository, ChatApi
//
//   registerFactory → nueva instancia en cada get<>().
//     Úsalo para BLoCs — cada pantalla debe tener su propio BLoC
//     con su propio ciclo de vida.
//     Ej: ChatBloc, ThreadsBloc
//
// ORDEN DE INICIALIZACIÓN — CRÍTICO:
//   Las dependencias deben registrarse antes de ser requeridas.
//   Orden correcto:
//     1. SharedPreferences (sin dependencias)
//     2. AppDatabase (sin dependencias)
//     3. ConnectivityMonitor (sin dependencias de la app)
//     4. DioClient (necesita SharedPreferences)
//     5. ChatApi (necesita DioClient)
//     6. ChatRepository (necesita AppDatabase + ChatApi)
//     7. OutboxWorker (necesita AppDatabase + DioClient + ConnectivityMonitor)
//     8. SyncEngine (necesita todo lo anterior)
//     9. BLoCs (factories — se crean al navegar a cada pantalla)

import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/chat_repository.dart';
import '../../features/chat/data/local/chat_local_ds.dart';
import '../../features/chat/data/remote/chat_api.dart';
import '../../features/chat/presentation/blocs/chat/chat_bloc.dart';
import '../../features/chat/presentation/blocs/threads/threads_bloc.dart';
import '../../features/chat/presentation/blocs/user/user_bloc.dart';
import '../database/app_database.dart';
import '../network/connectivity_monitor.dart';
import '../network/dio_client.dart';
import '../sync/outbox_worker.dart';
import '../sync/sync_engine.dart';

/// Instancia global del service locator.
///
/// Se accede desde cualquier parte de la app como:
///   `final repo = getIt<ChatRepository>();`
final GetIt getIt = GetIt.instance;

/// Configuración de la URL base del servidor.
///
/// En desarrollo usar la IP de la máquina local (no localhost)
/// porque el emulador Android no puede resolver 'localhost' del host.
///
/// iOS Simulator sí puede usar 'localhost' o '127.0.0.1'.
/// Para dispositivo físico, usar la IP de la red local (192.168.x.x).
class AppConfig {
  static const String _serverHost = String.fromEnvironment(
    'SERVER_HOST',
    defaultValue: '10.0.2.2', // default: emulador Android
  );

  static const String _env = String.fromEnvironment('ENV', defaultValue: 'development');

  static const String serverBaseUrl = 'http://$_serverHost:8080';
  static const String wsBaseUrl = 'ws://$_serverHost:8080';

  static const bool isProduction = _env == 'production';
  static const bool isDevelopment = _env == 'development';
}

/// Inicializa todas las dependencias de la aplicación.
///
/// Debe llamarse en main.dart ANTES de ejecutar runApp():
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await initDependencies();
///   runApp(const ChatSyncApp());
/// }
/// ```
///
/// Es async porque SharedPreferences.getInstance() es asíncrono.
Future<void> initDependencies() async {
  // =========================================================================
  // PASO 1 — SharedPreferences
  // =========================================================================
  // Sin dependencias. Se usa para persistir:
  //   · current_user_id → identificar al usuario actual
  //   · last_sync_at    → cursor del delta sync
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);

  // =========================================================================
  // PASO 2 — Base de datos local
  // =========================================================================
  // Drift abre la conexión SQLite al instanciar AppDatabase.
  // Los DAOs están disponibles como propiedades de la instancia.
  getIt.registerSingleton<AppDatabase>(AppDatabase());

  // =========================================================================
  // PASO 3 — Monitor de conectividad
  // =========================================================================
  // Se inicializa inmediatamente para tener el estado de red
  // disponible antes de que el OutboxWorker y SyncEngine arranquen.
  final connectivityMonitor = ConnectivityMonitor(
    serverBaseUrl: AppConfig.serverBaseUrl,
    pingTimeout: const Duration(seconds: 5),
    degradedRetryInterval: const Duration(seconds: 5),
  );
  await connectivityMonitor.initialize();
  getIt.registerSingleton<ConnectivityMonitor>(connectivityMonitor);

  // =========================================================================
  // PASO 4 — Cliente HTTP
  // =========================================================================
  // DioClient necesita SharedPreferences para el AuthInterceptor.
  getIt.registerSingleton<DioClient>(
    DioClient(baseUrl: AppConfig.serverBaseUrl, sharedPreferences: getIt<SharedPreferences>()),
  );

  // =========================================================================
  // PASO 5 — Data sources remotos
  // =========================================================================
  // ChatApi encapsula todas las llamadas HTTP al servidor Go.
  getIt.registerLazySingleton<ChatApi>(() => ChatApi(dio: getIt<DioClient>().dio));

  // =========================================================================
  // PASO 6 — Data sources locales
  // =========================================================================
  // ChatLocalDs accede a los DAOs de AppDatabase.
  getIt.registerLazySingleton<ChatLocalDs>(
    () => ChatLocalDs(database: getIt<AppDatabase>(), sharedPreferences: getIt<SharedPreferences>()),
  );

  // =========================================================================
  // PASO 7 — Repositorio
  // =========================================================================
  // ChatRepository orquesta local + remoto. Es la única fuente de verdad
  // para los BLoCs — nunca acceden a ChatApi o ChatLocalDs directamente.
  getIt.registerLazySingleton<ChatRepository>(
    () => ChatRepository(
      localDs: getIt<ChatLocalDs>(),
      remoteApi: getIt<ChatApi>(),
      connectivityMonitor: getIt<ConnectivityMonitor>(),
      sharedPreferences: getIt<SharedPreferences>(),
    ),
  );

  // =========================================================================
  // PASO 8 — OutboxWorker
  // =========================================================================
  // El worker se crea pero NO se inicia aquí.
  // Se inicia en el Paso 10, después de que SyncEngine también esté listo.
  // Esto evita que el worker procese operaciones antes de que el sync
  // inicial haya descargado el estado actual del servidor.
  getIt.registerSingleton<OutboxWorker>(
    OutboxWorker(
      database: getIt<AppDatabase>(),
      dioClient: getIt<DioClient>(),
      connectivityMonitor: getIt<ConnectivityMonitor>(),
    ),
  );

  // =========================================================================
  // PASO 9 — SyncEngine
  // =========================================================================
  // El currentUserId puede ser null en la primera ejecución (antes de
  // que el usuario se registre). En ese caso, el SyncEngine no intentará
  // sincronizar hasta que haya un userId válido.
  //
  // En una app real, el SyncEngine se recrearía/reiniciaría cuando el
  // usuario completa el registro.

  getIt.registerSingleton<SyncEngine>(
    SyncEngine(
      database: getIt<AppDatabase>(),
      dioClient: getIt<DioClient>(),
      connectivityMonitor: getIt<ConnectivityMonitor>(),
      sharedPreferences: getIt<SharedPreferences>(),
      wsBaseUrl: AppConfig.wsBaseUrl,
      currentUserId: "", // UserBloc lo reiniciará con el ID real
    ),
  );

  // =========================================================================
  // PASO 10 — BLoCs (factories)
  // =========================================================================
  // Los BLoCs se registran como factories: cada vez que se hace
  // getIt<XxxBloc>() se crea una nueva instancia.
  //
  // Esto es correcto para BLoCs porque:
  //   · Cada pantalla debe tener su propio BLoC con ciclo de vida propio
  //   · BlocProvider los cierra (close()) al desmontar la pantalla
  //   · No queremos estado compartido entre instancias de la misma pantalla

  // UserBloc: maneja creación y carga del usuario actual.
  // Se usa en CreateUserScreen y para verificar sesión en main.dart.
  getIt.registerFactory<UserBloc>(() => UserBloc(repository: getIt<ChatRepository>()));

  // ThreadsBloc: maneja la lista de conversaciones y búsqueda de usuarios.
  getIt.registerFactory<ThreadsBloc>(() => ThreadsBloc(repository: getIt<ChatRepository>()));

  // ChatBloc: maneja los mensajes de una conversación específica.
  // Recibe threadId como parámetro porque cada chat es independiente.
  // En la app, se creará así:
  //   BlocProvider(
  //     create: (_) => getIt<ChatBloc>()..add(LoadMessagesEvent(threadId)),
  //   )
  getIt.registerFactory<ChatBloc>(() => ChatBloc(repository: getIt<ChatRepository>()));
}

/// Inicia los workers después del registro del usuario.
///
/// Se llama desde UserBloc cuando el usuario completa el registro
/// por primera vez, o al cargar una sesión existente.
///
/// Esto asegura que OutboxWorker y SyncEngine siempre tienen un
/// userId válido cuando empiezan a operar.
void startWorkersAfterLogin(String userId) {
  // Reiniciar el SyncEngine con el userId correcto si ya estaba corriendo
  final syncEngine = getIt<SyncEngine>();
  syncEngine.dispose();

  // Reemplazar la instancia con una nueva que tiene el userId correcto
  getIt.unregister<SyncEngine>();
  getIt.registerSingleton<SyncEngine>(
    SyncEngine(
      database: getIt<AppDatabase>(),
      dioClient: getIt<DioClient>(),
      connectivityMonitor: getIt<ConnectivityMonitor>(),
      sharedPreferences: getIt<SharedPreferences>(),
      wsBaseUrl: AppConfig.wsBaseUrl,
      currentUserId: userId,
    ),
  );

  getIt<OutboxWorker>().start();
  getIt<SyncEngine>().start();
}


/*
Las decisiones más importantes del injector:
Orden de inicialización — el orden de los 10 pasos no es arbitrario. 
SharedPreferences va primero porque DioClient lo necesita para el AuthInterceptor. 
ConnectivityMonitor va antes que OutboxWorker y SyncEngine porque ambos se suscriben a su stream en el start(). 
Si se invirtiera el orden, start() se llamaría sobre un monitor que aún no existe.
registerSingleton vs registerLazySingleton vs registerFactory 
— los singletons son para infraestructura que debe existir desde el arranque (AppDatabase, ConnectivityMonitor). 
Los lazy singletons son para capas que solo se necesitan cuando hay un usuario activo (ChatRepository, ChatApi). 
Los factories son para BLoCs — cada pantalla obtiene su propia instancia con ciclo de vida independiente que BlocProvider cierra al desmontarla.
Workers se inician en Paso 10, no en Paso 8/9 — el OutboxWorker y SyncEngine se crean antes pero se inician al final. 
Si se iniciaran en su propio paso, el worker podría empezar a procesar el outbox antes de que 
el SyncEngine haya descargado el estado del servidor, generando conflictos.
startWorkersAfterLogin() — función pública para reiniciar el SyncEngine con el userId correcto después del registro. 
En la primera ejecución el userId es vacío, así que los workers no corren. 
El UserBloc llama esta función cuando el usuario completa su registro, pasando el UUID real.
AppConfig — 10.0.2.2 es la IP especial que el emulador Android usa para referirse al host de desarrollo. 
iOS Simulator puede usar localhost. Para dispositivo físico se cambia por la IP de la red local.
*/