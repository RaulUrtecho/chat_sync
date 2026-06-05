// Interceptor de retry con backoff exponencial para Dio.
//
// PROBLEMA QUE RESUELVE:
//   En redes móviles, los fallos de red son transitorios con frecuencia:
//   un paquete se pierde, el servidor estaba en un deploy de 2 segundos,
//   hay un spike de tráfico momentáneo. Reintentar inmediatamente el mismo
//   request suele resolver estos casos sin que el usuario note nada.
//
// BACKOFF EXPONENCIAL:
//   En lugar de reintentar cada N segundos fijos (retry lineal), el backoff
//   exponencial aumenta el tiempo de espera entre intentos:
//     Intento 1 → espera 1s  (2^0)
//     Intento 2 → espera 2s  (2^1)
//     Intento 3 → espera 4s  (2^2)
//     Intento 4 → espera 8s  (2^3)  ← tope máximo
//
//   Esto evita saturar el servidor cuando está bajo presión: si muchos
//   clientes están reintentando simultáneamente, el backoff los dispersa
//   en el tiempo reduciendo la carga total.
//
// QUÉ SE REINTENTA:
//   · Errores de conexión (sin red, timeout, DNS)
//   · Respuestas 503 Service Unavailable
//   · Respuestas 502 Bad Gateway
//   · Respuestas 504 Gateway Timeout
//
// QUÉ NO SE REINTENTA:
//   · 4xx (errores del cliente: bad request, not found, etc.)
//     → reintentar no ayuda, el request está mal formado
//   · 401 Unauthorized
//     → el problema es de credenciales, no de red
//   · POST que no son idempotentes (enviados sin idempotency key)
//     → riesgo de duplicados
//
// NOTA SOBRE EL OUTBOX:
//   Este interceptor maneja reintentos a nivel de request HTTP individual
//   (transitorios, segundos). El OutboxWorker maneja reintentos a nivel
//   de operación de negocio (persistentes, minutos/horas). Son dos capas
//   distintas de resiliencia que se complementan.

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

/// Interceptor que reintenta automáticamente requests fallidos
/// con backoff exponencial.
///
/// Se agrega a la instancia de Dio en [DioClient].
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required Dio dio,
    int maxRetries = 3,
    Duration initialDelay = const Duration(seconds: 1),
    Duration maxDelay = const Duration(seconds: 8),
  }) : _dio = dio,
       _maxRetries = maxRetries,
       _initialDelay = initialDelay,
       _maxDelay = maxDelay;

  /// Referencia al Dio principal para re-ejecutar requests.
  ///
  /// IMPORTANTE: debe ser la misma instancia de Dio que tiene este
  /// interceptor registrado. No crear un Dio nuevo aquí.
  final Dio _dio;

  /// Número máximo de reintentos antes de propagar el error.
  final int _maxRetries;

  /// Delay base del backoff (delay del primer reintento).
  final Duration _initialDelay;

  /// Delay máximo entre reintentos (techo del backoff exponencial).
  final Duration _maxDelay;

  /// Clave en RequestOptions.extra para rastrear el intento actual.
  ///
  /// Drift usa options.extra como un mapa de metadata personalizada.
  /// Almacenamos aquí el número de intento para sobrevivir entre
  /// llamadas al interceptor sin estado externo.
  static const String _retryCountKey = 'retry_count';

  // ---------------------------------------------------------------------------
  // INTERCEPTOR — onError
  // ---------------------------------------------------------------------------

  /// Se ejecuta cuando Dio recibe un error (de red o HTTP).
  ///
  /// Decide si reintentar el request o propagar el error al llamador.
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;

    // Leer el número de intento actual (0 = primer intento original)
    final retryCount = (options.extra[_retryCountKey] as int?) ?? 0;

    // Decidir si este error es reintentable
    if (!_shouldRetry(err) || retryCount >= _maxRetries) {
      // No reintentable o agotamos los reintentos → propagar error
      return handler.next(err);
    }

    // Calcular delay con backoff exponencial:
    //   delay = min(initialDelay * 2^retryCount, maxDelay)
    //   retryCount=0 → 1s, 1 → 2s, 2 → 4s, 3 → 8s
    final delay = _calculateDelay(retryCount);

    // Esperar antes de reintentar
    await Future.delayed(delay);

    // Incrementar el contador de reintentos en el request
    options.extra[_retryCountKey] = retryCount + 1;

    try {
      // Re-ejecutar el mismo request con las mismas opciones
      final response = await _dio.fetch(options);
      // Éxito → resolver el handler con la respuesta
      return handler.resolve(response);
    } on DioException catch (retryError) {
      // El reintento también falló → propagar el error del reintento
      return handler.next(retryError);
    }
  }

  // ---------------------------------------------------------------------------
  // HELPERS PRIVADOS
  // ---------------------------------------------------------------------------

  /// Determina si un error de Dio es candidato para reintento.
  ///
  /// Solo se reintenta:
  ///   · Errores de conexión (sin red, socket cerrado)
  ///   · Timeouts (send o receive)
  ///   · Errores 5xx específicos (503, 502, 504)
  bool _shouldRetry(DioException err) {
    // Errores de red/conexión → siempre reintentar
    if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout) {
      return true;
    }

    // Errores HTTP específicos del servidor → reintentar
    final statusCode = err.response?.statusCode;
    if (statusCode != null) {
      return statusCode == 503 || // Service Unavailable
          statusCode == 502 || // Bad Gateway
          statusCode == 504; // Gateway Timeout
    }

    return false;
  }

  /// Calcula el delay del próximo reintento con backoff exponencial.
  ///
  /// Fórmula: min(initialDelay * 2^retryCount, maxDelay)
  ///
  /// [retryCount] número de reintentos ya realizados (empieza en 0).
  Duration _calculateDelay(int retryCount) {
    final exponentialMs = _initialDelay.inMilliseconds * pow(2, retryCount).toInt();
    final cappedMs = min(exponentialMs, _maxDelay.inMilliseconds);
    return Duration(milliseconds: cappedMs);
  }
}
