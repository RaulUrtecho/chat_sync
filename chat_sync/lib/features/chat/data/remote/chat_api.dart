// ChatApi — Data source remoto.
//
// Encapsula TODAS las llamadas HTTP al servidor Go. Ninguna otra capa
// de la app toca Dio directamente — solo ChatApi.
//
// RESPONSABILIDAD ÚNICA:
//   Traducir entre el lenguaje de la app (entidades Dart) y el
//   protocolo HTTP del servidor (JSON, endpoints, status codes).
//
// QUÉ NO HACE:
//   · No persiste nada localmente
//   · No decide si hay o no conexión
//   · No tiene lógica de negocio
//   · No maneja reintentos (eso es del RetryInterceptor de Dio)
//
// ENDPOINTS DEL SERVIDOR GO:
//   POST   /users                      → registrar usuario
//   GET    /users/search?q=            → buscar usuarios por nombre
//   POST   /threads                    → crear thread
//   GET    /threads?userId=&since=     → listar threads del usuario
//   POST   /messages                   → enviar mensaje
//   GET    /messages/:threadId?since=  → listar mensajes de un thread

import 'package:dio/dio.dart';

/// Data source remoto que encapsula las llamadas HTTP al servidor Go.
class ChatApi {
  ChatApi({required Dio dio}) : _dio = dio;

  final Dio _dio;

  // ---------------------------------------------------------------------------
  // USUARIOS
  // ---------------------------------------------------------------------------

  /// Registra un nuevo usuario en el servidor.
  ///
  /// Se llama desde el outbox cuando se procesa una operación
  /// de tipo [OutboxOperationType.createUser].
  ///
  /// El [idempotencyKey] es el UUID del usuario — si el servidor
  /// ya registró este UUID, retorna 200 sin crear un duplicado.
  Future<Map<String, dynamic>> createUser({required String id, required String name, required Options options}) async {
    final response = await _dio.post('/users', data: {'id': id, 'name': name}, options: options);
    return response.data as Map<String, dynamic>;
  }

  /// Busca usuarios por nombre en el servidor.
  ///
  /// Se usa en el search bar de ThreadsScreen para encontrar
  /// contactos con los que iniciar una conversación.
  ///
  /// [query] texto de búsqueda (mínimo 1 caracter).
  /// Retorna lista de usuarios que coinciden con el nombre.
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final response = await _dio.get('/users/search', queryParameters: {'q': query});
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  // ---------------------------------------------------------------------------
  // THREADS
  // ---------------------------------------------------------------------------

  /// Crea un nuevo thread en el servidor.
  ///
  /// Se llama desde el outbox para sincronizar threads creados offline.
  ///
  /// [userAId] siempre es el usuario actual (quien inicia la conversación).
  /// [userBId] es el contacto con quien se conversa.
  Future<Map<String, dynamic>> createThread({
    required String id,
    required String userAId,
    required String userBId,
    required Options options,
  }) async {
    final response = await _dio.post(
      '/threads',
      data: {'id': id, 'user_a_id': userAId, 'user_b_id': userBId},
      options: options,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Obtiene los threads del usuario desde el servidor.
  ///
  /// [since] si se proporciona, solo retorna threads creados o
  /// actualizados después de este timestamp (delta sync).
  Future<List<Map<String, dynamic>>> getThreads({required String userId, DateTime? since}) async {
    final queryParams = <String, dynamic>{'userId': userId};
    if (since != null) {
      queryParams['since'] = since.toUtc().toIso8601String();
    }

    final response = await _dio.get('/threads', queryParameters: queryParams);
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  // ---------------------------------------------------------------------------
  // MENSAJES
  // ---------------------------------------------------------------------------

  /// Envía un mensaje al servidor.
  ///
  /// Se llama desde el outbox cuando hay conexión disponible.
  /// El [options] incluye el X-Idempotency-Key para prevenir duplicados.
  Future<Map<String, dynamic>> sendMessage({
    required String id,
    required String threadId,
    required String senderId,
    required String content,
    required DateTime createdAt,
    required Options options,
  }) async {
    final response = await _dio.post(
      '/messages',
      data: {
        'id': id,
        'thread_id': threadId,
        'sender_id': senderId,
        'content': content,
        'created_at': createdAt.toUtc().toIso8601String(),
      },
      options: options,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Obtiene los mensajes de un thread desde el servidor.
  ///
  /// [since] permite el delta sync: solo mensajes después de este timestamp.
  /// Si [since] es null, retorna todos los mensajes del thread.
  Future<List<Map<String, dynamic>>> getMessages({required String threadId, DateTime? since}) async {
    final queryParams = <String, dynamic>{};
    if (since != null) {
      queryParams['since'] = since.toUtc().toIso8601String();
    }

    final response = await _dio.get('/messages/$threadId', queryParameters: queryParams);
    return (response.data as List).cast<Map<String, dynamic>>();
  }
}
