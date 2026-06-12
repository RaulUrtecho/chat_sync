// lib/main.dart
//
// Punto de entrada de la aplicación ChatSync.
//
// SECUENCIA DE ARRANQUE:
//   1. WidgetsFlutterBinding.ensureInitialized()
//      → Necesario antes de cualquier operación async en main()
//
//   2. initDependencies()
//      → Inicializa get_it: SharedPreferences, AppDatabase,
//        ConnectivityMonitor, DioClient, Repository, Workers, BLoCs
//
//   3. runApp(ChatSyncApp())
//      → Lanza la app con el MaterialApp configurado
//
//   4. ChatSyncApp despacha CheckCurrentUserEvent
//      → Si hay usuario guardado → ThreadsScreen
//      → Si no hay usuario      → CreateUserScreen

import 'package:chat_sync/core/notifications/notification_service.dart';
import 'package:chat_sync/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/di/injector.dart';
import 'features/chat/presentation/blocs/user/user_bloc.dart';
import 'features/chat/presentation/screens/create_user_screen.dart';
import 'features/chat/presentation/screens/threads_screen.dart';
// import 'package:path_provider/path_provider.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // Requerido antes de cualquier llamada async en main()
  // Inicializa el binding entre Flutter y el engine nativo.
  WidgetsFlutterBinding.ensureInitialized();

  // Fijar la orientación del dispositivo a vertical (portrait)
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);

  // Este codigo es para borrar solo SQLITE para pruebas
  // final dbFile = await _getDbFile();
  // if (await dbFile.exists()) await dbFile.delete();

  // Inicializar todas las dependencias en orden correcto.
  // Este método es async porque SharedPreferences.getInstance() lo es.
  // Ver: lib/core/di/injector.dart para el detalle de cada paso.
  await initDependencies();
  // Inicializar Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Inicializar notificaciones
  await NotificationService.instance.initialize();
  await initializeDateFormatting('es', null);

  runApp(const ChatSyncApp());
}

/// Widget raíz de la aplicación.
///
/// Configura el MaterialApp y el BLoC de usuario que decide
/// qué pantalla mostrar al iniciar.
class ChatSyncApp extends StatelessWidget {
  const ChatSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChatSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light),
        useMaterial3: true,
      ),
      navigatorKey: navigatorKey,
      // BlocProvider en el nivel raíz para que UserBloc
      // esté disponible en toda la árbol de widgets durante
      // la verificación inicial de sesión.
      home: BlocProvider(
        create: (_) => getIt<UserBloc>()..add(const CheckCurrentUserEvent()),
        child: const _AuthGate(),
      ),
    );
  }
}

/// Gate de autenticación — decide qué pantalla mostrar al iniciar.
///
/// Escucha el estado del UserBloc para navegar a la pantalla correcta:
///   · UserInitial / UserLoading → splash con indicador de carga
///   · UserLoaded                → ThreadsScreen
///   · UserNotFound              → CreateUserScreen
///   · UserError                 → CreateUserScreen con mensaje de error
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    debugPrint('🔍 serverBaseUrl: ${AppConfig.serverBaseUrl}');
    debugPrint('🔍 wsBaseUrl: ${AppConfig.wsBaseUrl}');
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, state) {
        return switch (state) {
          // Verificando sesión — splash screen
          UserInitial() || UserLoading() => const Scaffold(body: Center(child: CircularProgressIndicator())),

          // Usuario registrado → ir directo a los chats
          UserLoaded() => const ThreadsScreen(),

          // Sin usuario → pantalla de registro
          UserNotFound() => const CreateUserScreen(),

          // Error al cargar sesión → mostrar registro con aviso
          UserError(:final message) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 12),
                  Text(message),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => context.read<UserBloc>().add(const CheckCurrentUserEvent()),
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
        };
      },
    );
  }
}

// Para borrar solo SQLite en desarrollo:
// Future<File> _getDbFile() async {
//   final dir = await getApplicationDocumentsDirectory();
//   return File('${dir.path}/chat_sync.db');
// }
