// lib/core/notifications/notification_service.dart
//
// Servicio de notificaciones push con Firebase Messaging.
//
// RESPONSABILIDADES:
//   · Solicitar permisos de notificación al usuario
//   · Obtener el FCM token del dispositivo
//   · Manejar notificaciones en foreground, background y app cerrada
//   · Mostrar notificaciones locales cuando la app está en foreground

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

// Handler para mensajes en background — debe ser top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No necesita inicializar Firebase aquí — ya está inicializado
  debugPrint('📬 [FCM] Mensaje en background: ${message.messageId}');
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _messaging = FirebaseMessaging.instance;
  final _localNotifications = FlutterLocalNotificationsPlugin();

  // Canal de Android para mensajes de chat
  static const _androidChannel = AndroidNotificationChannel(
    'chat_messages',
    'Mensajes de Chat',
    description: 'Notificaciones de mensajes nuevos',
    importance: Importance.high,
  );

  /// Inicializa el servicio de notificaciones.
  /// Llamar en main.dart después de Firebase.initializeApp()
  Future<void> initialize() async {
    // 1. Registrar handler de background
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // 2. Solicitar permisos
    await _requestPermissions();

    // 3. Configurar notificaciones locales (para foreground)
    await _initLocalNotifications();

    // 4. Crear canal de Android
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    // 5. Manejar mensajes en foreground
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
  }

  /// Solicita permisos de notificación al usuario.
  Future<void> _requestPermissions() async {
    final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
    debugPrint('📬 [FCM] Permiso: ${settings.authorizationStatus}');
  }

  /// Inicializa flutter_local_notifications.
  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(settings: initSettings);
  }

  /// Muestra una notificación local cuando la app está en foreground.
  ///
  /// FCM no muestra notificaciones automáticamente en foreground —
  /// necesitamos mostrarlas manualmente con flutter_local_notifications.
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

  /// Obtiene el FCM token del dispositivo.
  ///
  /// Este token identifica el dispositivo en FCM.
  /// El backend lo necesita para enviar notificaciones a este dispositivo.
  Future<String?> getToken() async {
    final token = await _messaging.getToken();
    debugPrint('📬 [FCM] Token: $token');
    return token;
  }

  /// Stream que emite cuando el token FCM se actualiza.
  ///
  /// El token puede cambiar — el backend debe actualizarlo.
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;
}
