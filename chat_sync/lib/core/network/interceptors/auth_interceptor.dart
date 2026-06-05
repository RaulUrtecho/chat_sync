// Interceptor de autenticación para Dio.
//
// En este proyecto no hay JWT ni OAuth — la "autenticación" es simplemente
// identificar al usuario que hace cada request mediante su ID en los headers.
// El servidor usa este header para saber quién envía cada mensaje o crea
// cada thread, sin necesidad de un sistema de sesiones complejo.
//
// HEADER INYECTADO:
//   X-User-Id: {uuid-del-usuario-actual}
//
// PATRÓN INTERCEPTOR DE DIO:
//   onRequest → se ejecuta ANTES de enviar cada request
//   onResponse → se ejecuta DESPUÉS de recibir cada respuesta (no usado aquí)
//   onError → se ejecuta cuando ocurre un error HTTP (no usado aquí)
//
// Este interceptor solo actúa en onRequest: agrega el header antes de
// que el request salga hacia el servidor.

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Interceptor que inyecta el ID del usuario actual en cada request HTTP.
///
/// Se agrega a la instancia de Dio una sola vez en [DioClient].
/// A partir de ese momento, TODOS los requests salientes incluirán
/// automáticamente el header X-User-Id sin necesidad de recordarlo
/// en cada llamada individual.
///
/// Si no hay usuario registrado aún (primera vez en la app),
/// el header simplemente no se agrega y el request sale sin él.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required SharedPreferences sharedPreferences}) : _prefs = sharedPreferences;

  final SharedPreferences _prefs;

  // Clave usada para almacenar el userId en SharedPreferences.
  // Debe ser consistente con el valor que guarda UserRepository
  // al crear el usuario.
  static const String _userIdKey = 'current_user_id';

  /// Se ejecuta antes de enviar cada request.
  ///
  /// Inyecta el header X-User-Id si hay un usuario registrado.
  /// Llama [handler.next(options)] para continuar con el pipeline
  /// de interceptores y eventualmente enviar el request.
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final userId = _prefs.getString(_userIdKey);

    if (userId != null) {
      // Agregar el header a las opciones del request.
      // No modificamos options directamente — creamos una copia
      // con copyWith para evitar mutaciones inesperadas.
      options.headers['X-User-Id'] = userId;
    }

    // Continuar con el siguiente interceptor en la cadena
    // (o enviar el request si este es el último interceptor).
    handler.next(options);
  }
}
