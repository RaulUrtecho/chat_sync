// Servicio de notificaciones push con Firebase Messaging.
//
// RESPONSABILIDADES:
//   · Solicitar permisos de notificación al usuario
//   · Obtener el FCM token del dispositivo
//   · Manejar notificaciones en foreground, background y app cerrada
//   · Mostrar notificaciones locales cuando la app está en foreground
//
// CASOS DE NAVEGACIÓN AL TOCAR UNA NOTIFICACIÓN:
//
//   App en foreground  → _handleForegroundMessage muestra notif local
//                        onMessageOpenedApp navega directamente
//
//   App en background  → onMessageOpenedApp navega directamente
//                        navigatorKey ya está listo
//
//   App cerrada        → getInitialMessage guarda el threadId pendiente
//                        NO navega inmediatamente porque el árbol de
//                        widgets aún no está montado (navigatorKey = null)
//                        ThreadsScreen verifica el pending en initState
//                        y navega cuando ya está lista

import 'package:chat_sync/features/chat/presentation/screens/chat_screen.dart';
import 'package:chat_sync/main.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

// Handler para mensajes en background — debe ser top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📬 [FCM] Mensaje en background: ${message.messageId}');
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _messaging = FirebaseMessaging.instance;
  final _localNotifications = FlutterLocalNotificationsPlugin();

  static const _androidChannel = AndroidNotificationChannel(
    'chat_messages',
    'Mensajes de Chat',
    description: 'Notificaciones de mensajes nuevos',
    importance: Importance.high,
  );

  // ---------------------------------------------------------------------------
  // PENDING NAVIGATION
  // ---------------------------------------------------------------------------
  // Cuando la app estaba CERRADA y el usuario toca la notificación,
  // el árbol de widgets aún no está montado y navigatorKey.currentState
  // es null. En lugar de navegar inmediatamente (que fallaría silenciosamente),
  // guardamos el threadId aquí. ThreadsScreen lo verifica en initState
  // una vez que ya está montada y navega al ChatScreen correcto.
  String? _pendingThreadId;
  String? _pendingSenderName;

  /// ThreadId pendiente de navegación (app estaba cerrada).
  String? get pendingThreadId => _pendingThreadId;

  /// Nombre del sender pendiente de navegación.
  String? get pendingSenderName => _pendingSenderName;

  /// Limpia la navegación pendiente después de procesarla.
  /// Llamar desde ThreadsScreen después de navegar al ChatScreen.
  void clearPending() {
    _pendingThreadId = null;
    _pendingSenderName = null;
  }

  // ---------------------------------------------------------------------------
  // INICIALIZACIÓN
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _requestPermissions();
    await _initLocalNotifications();

    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    // Foreground
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Background → tap → navegar directamente (navigatorKey listo)
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleNotificationTap(message.data);
    });

    // App cerrada → tap → guardar como pending
    // ThreadsScreen procesará la navegación cuando esté montada
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _pendingThreadId = initialMessage.data['thread_id'] as String?;
      _pendingSenderName = initialMessage.data['sender_name'] as String? ?? 'Chat';
      debugPrint('📬 [FCM] Navegación pendiente al thread: $_pendingThreadId');
    }
  }

  Future<void> _requestPermissions() async {
    final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
    debugPrint('📬 [FCM] Permiso: ${settings.authorizationStatus}');
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(settings: initSettings);
  }

  /// Muestra notificación local cuando la app está en foreground.
  /// FCM no las muestra automáticamente en foreground.
  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('📬 [FCM] Mensaje en foreground: ${message.messageId}');
    final notification = message.notification;
    if (notification == null) return;

    _localNotifications.show(
      id: notification.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  /// Navega al ChatScreen cuando el usuario toca la notificación.
  /// Solo para app en background — app cerrada usa el sistema de pending.
  void _handleNotificationTap(Map<String, dynamic> data) {
    final threadId = data['thread_id'] as String?;
    final senderName = data['sender_name'] as String? ?? 'Chat';
    if (threadId == null) return;

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(threadId: threadId, participantName: senderName),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TOKEN FCM
  // ---------------------------------------------------------------------------

  Future<String?> getToken() async {
    final token = await _messaging.getToken();
    debugPrint('📬 [FCM] Token: $token');
    return token;
  }

  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;
}
