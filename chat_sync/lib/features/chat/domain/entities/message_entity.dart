// Entidad de dominio: Mensaje.
//
// Es la entidad más rica en comportamiento del proyecto porque encapsula
// todo el ciclo de vida offline de un mensaje a través de [MessageStatus].
//
// CICLO DE VIDA VISUAL:
//
//   Usuario escribe → MessageStatus.pending  (⏱ reloj en UI)
//         ↓
//   Server confirma → MessageStatus.sent     (✓ check en UI)
//         ↓ (si falla N veces)
//   Max retries     → MessageStatus.failed   (✗ error en UI)
//
//   Mensaje recibido → MessageStatus.received (sin ícono, burbuja izquierda)

import 'package:equatable/equatable.dart';

/// Estados posibles de un mensaje en su ciclo de vida offline.
enum MessageStatus {
  /// Guardado localmente, en cola para enviar al servidor.
  /// El usuario lo ve inmediatamente (Optimistic UI).
  /// Icono: ⏱ reloj
  pending,

  /// Confirmado por el servidor. La sincronización fue exitosa.
  /// Icono: ✓ check
  sent,

  /// Falló después de [maxRetries] intentos.
  /// El usuario puede intentar reenviar manualmente.
  /// Icono: ✗ error
  failed,

  /// Mensaje recibido de otro usuario.
  /// Ya sincronizado — vino del servidor directamente.
  /// Sin ícono de estado (burbuja del lado izquierdo).
  received;

  /// Convierte un String almacenado en la DB a [MessageStatus].
  static MessageStatus fromString(String value) {
    return MessageStatus.values.firstWhere((s) => s.name == value, orElse: () => MessageStatus.pending);
  }
}

/// Representa un mensaje individual en una conversación.
class MessageEntity extends Equatable {
  const MessageEntity({
    required this.id,
    required this.threadId,
    required this.senderId,
    required this.content,
    required this.status,
    required this.createdAt,
    required this.isFromCurrentUser,
  });

  final String id;
  final String threadId;
  final String senderId;
  final String content;
  final MessageStatus status;
  final DateTime createdAt;

  /// Indica si este mensaje fue enviado por el usuario del dispositivo.
  ///
  /// Se usa en la UI para:
  ///   · Alinear la burbuja a la derecha (true) o izquierda (false)
  ///   · Mostrar o no el ícono de status (solo en mensajes propios)
  ///   · Colorear la burbuja diferente
  final bool isFromCurrentUser;

  /// Retorna true si el mensaje aún no llegó al servidor.
  bool get isPending => status == MessageStatus.pending;

  /// Retorna true si el mensaje falló la sincronización.
  bool get isFailed => status == MessageStatus.failed;

  /// Retorna true si el mensaje fue confirmado por el servidor.
  bool get isSent => status == MessageStatus.sent;

  /// Crea una copia del mensaje con campos actualizados.
  ///
  /// Se usa en el BLoC cuando se actualiza el status de un mensaje
  /// sin reemplazar toda la lista.
  MessageEntity copyWith({
    String? id,
    String? threadId,
    String? senderId,
    String? content,
    MessageStatus? status,
    DateTime? createdAt,
    bool? isFromCurrentUser,
  }) {
    return MessageEntity(
      id: id ?? this.id,
      threadId: threadId ?? this.threadId,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      isFromCurrentUser: isFromCurrentUser ?? this.isFromCurrentUser,
    );
  }

  @override
  List<Object?> get props => [id, threadId, senderId, content, status, createdAt, isFromCurrentUser];

  @override
  String toString() => 'MessageEntity(id: $id, status: ${status.name}, content: $content)';
}
