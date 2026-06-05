// Cliente HTTP principal de la aplicación.
//
// Configura y ensambla una instancia de Dio con todos los interceptores
// necesarios para el soporte offline robusto:
//
//   1. AuthInterceptor    → inyecta X-User-Id en cada request
//   2. RetryInterceptor   → reintenta con backoff exponencial en fallos
//   3. LogInterceptor     → logging de requests/responses (solo en debug)
//
// ORDEN DE INTERCEPTORES — IMPORTANTE:
//   Los interceptores se ejecutan en el orden en que se agregan.
//   Para onRequest: primero AuthInterceptor, luego RetryInterceptor
//   Para onError:   primero RetryInterceptor (decide si reintenta)
//
//   Auth debe ir antes que Retry para que los reintentos también
//   incluyan el header X-User-Id correctamente.
//
// USO:
//   DioClient se registra como singleton en get_it.
//   ChatApi recibe la instancia de Dio mediante inyección de dependencias.
//
//   // En el inyector:
//   getIt.registerSingleton<DioClient>(
//     DioClient(
//       sharedPreferences: getIt<SharedPreferences>(),
//       baseUrl: AppConfig.serverBaseUrl,
//     ),
//   );
//
//   // En ChatApi:
//   final dio = getIt<DioClient>().dio;
//   final response = await dio.post('/messages', data: {...});

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interceptors/auth_interceptor.dart';
import 'interceptors/retry_interceptor.dart';

/// Cliente HTTP configurado para ChatSync.
///
/// Expone la instancia [dio] lista para usar en los datasources remotos.
/// No hacer requests directamente con esta clase — usar [ChatApi].
class DioClient {
  DioClient({
    required String baseUrl,
    required SharedPreferences sharedPreferences,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration receiveTimeout = const Duration(seconds: 15),
    Duration sendTimeout = const Duration(seconds: 10),
  }) {
    // ---------------------------------------------------------------------------
    // 1. CONFIGURACIÓN BASE DE DIO
    // ---------------------------------------------------------------------------
    _dio = Dio(
      BaseOptions(
        // URL base del servidor — todos los endpoints son relativos a esto.
        // Ej: baseUrl='http://192.168.1.1:8080' + path='/messages'
        //     → 'http://192.168.1.1:8080/messages'
        baseUrl: baseUrl,

        // Timeout para establecer la conexión TCP con el servidor.
        // Si el servidor no acepta la conexión en este tiempo → error.
        connectTimeout: connectTimeout,

        // Timeout para recibir datos del servidor.
        // Si el servidor acepta pero no responde en este tiempo → error.
        receiveTimeout: receiveTimeout,

        // Timeout para enviar el request al servidor.
        // Relevante para uploads o payloads grandes.
        sendTimeout: sendTimeout,

        // Content-Type por defecto para todos los requests.
        // El servidor Go espera JSON.
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},

        // Lanzar DioException para respuestas 4xx y 5xx.
        // Sin esto, Dio trataría un 404 como respuesta exitosa.
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      ),
    );

    // ---------------------------------------------------------------------------
    // 2. INTERCEPTORES — en orden de ejecución
    // ---------------------------------------------------------------------------

    // AuthInterceptor: agrega X-User-Id a cada request.
    // Va primero para que todos los reintentos también tengan el header.
    _dio.interceptors.add(AuthInterceptor(sharedPreferences: sharedPreferences));

    // RetryInterceptor: reintenta con backoff exponencial.
    // Recibe la misma instancia de _dio para poder re-ejecutar requests.
    _dio.interceptors.add(
      RetryInterceptor(
        dio: _dio,
        maxRetries: 3,
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 8),
      ),
    );

    // LogInterceptor: logging de requests y responses.
    // SOLO en modo debug — nunca en producción (puede loggear datos sensibles).
    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(
          // Loggear el body del request (útil para ver el JSON enviado)
          requestBody: true,
          // Loggear el body del response (útil para ver errores del server)
          responseBody: true,
          // Loggear headers (útil para verificar X-User-Id y X-Idempotency-Key)
          requestHeader: true,
          responseHeader: false,
          // Usar print estándar de Flutter en lugar de developer.log
          logPrint: (obj) => debugPrint('[DioClient] $obj'),
        ),
      );
    }
  }

  late final Dio _dio;

  /// Instancia de Dio configurada y lista para usar.
  ///
  /// Los datasources remotos (ChatApi) reciben esta instancia.
  Dio get dio => _dio;

  // ---------------------------------------------------------------------------
  // HELPERS PARA HEADERS ESPECIALES
  // ---------------------------------------------------------------------------

  /// Crea opciones de request con el header X-Idempotency-Key.
  ///
  /// Se usa para operaciones del outbox (envío de mensajes, creación de
  /// threads) donde necesitamos garantizar que un reintento no cree
  /// duplicados en el servidor.
  ///
  /// El servidor Go debe verificar este key y retornar 200/201 si ya
  /// procesó la operación, en lugar de procesarla nuevamente.
  ///
  /// USO:
  /// ```dart
  /// await dio.post(
  ///   '/messages',
  ///   data: messageJson,
  ///   options: dioClient.idempotentOptions(message.id),
  /// );
  /// ```
  Options idempotentOptions(String idempotencyKey) => Options(headers: {'X-Idempotency-Key': idempotencyKey});

  /// Crea opciones de request con un CancelToken ya asociado.
  ///
  /// Se usa cuando queremos poder cancelar un request en vuelo,
  /// por ejemplo al salir de la pantalla de chat antes de que
  /// termine la carga de mensajes.
  ///
  /// USO:
  /// ```dart
  /// final cancelToken = CancelToken();
  /// await dio.get(
  ///   '/messages/$threadId',
  ///   cancelToken: cancelToken,
  /// );
  /// // Para cancelar:
  /// cancelToken.cancel('User left screen');
  /// ```
  static Options cancelableOptions(CancelToken cancelToken) => Options(
    // CancelToken se pasa directamente a Dio, no en Options.
    // Este helper existe como referencia de uso — ver ChatApi.
  );
}


/*
Puntos clave del paso:
auth_interceptor.dart — el interceptor más simple: lee el userId de SharedPreferences en cada request 
y lo inyecta como X-User-Id. Si no hay usuario aún (primera apertura), el header se omite silenciosamente. 
El servidor Go usa este header para saber quién envía cada operación.
retry_interceptor.dart — actúa en onError. 
Usa options.extra como mapa de metadata para guardar el retry_count entre llamadas sin estado externo. 
La fórmula min(initialDelay * 2^retryCount, maxDelay) da el backoff clásico con techo. 
Solo reintenta errores de conexión/timeout y 502/503/504 
— nunca 4xx porque un bad request seguirá siendo bad request sin importar cuántas veces se reintente.
dio_client.dart — el orden de los interceptores importa: Auth → Retry → Log. 
Auth va primero para que los reintentos del RetryInterceptor también salgan con el header correcto. 
LogInterceptor va último con guard de kDebugMode — en producción no loggea nada.
idempotentOptions() — helper clave que agrega X-Idempotency-Key al request. 
El OutboxWorker lo usará en cada operación de envío para que el servidor rechace duplicados silenciosamente en caso de retry tras timeout.
*/