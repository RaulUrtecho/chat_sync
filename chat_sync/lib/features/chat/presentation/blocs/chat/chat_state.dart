part of 'chat_bloc.dart';

sealed class ChatState extends Equatable {
  const ChatState();

  @override
  List<Object> get props => [];
}

/// Estado inicial antes de cargar mensajes.
final class ChatInitial extends ChatState {
  const ChatInitial();
}

/// Cargando mensajes por primera vez.
final class ChatLoading extends ChatState {
  const ChatLoading();
}

/// Mensajes disponibles y stream activo.
///
/// Se emite con cada cambio en Drift:
///   · Nuevo mensaje enviado (status: pending ⏱)
///   · OutboxWorker confirma envío (status: sent ✓)
///   · Mensaje recibido vía WebSocket o delta sync
///   · Mensaje falla tras N reintentos (status: failed ✗)
///
/// [hasPendingMessages] → la UI puede mostrar indicador de sync sutil.
/// [hasFailedMessages]  → la UI puede mostrar aviso de error.
final class ChatLoaded extends ChatState {
  const ChatLoaded({required this.messages, required this.threadId});

  final List<MessageEntity> messages;
  final String threadId;

  bool get hasPendingMessages => messages.any((m) => m.status == MessageStatus.pending);

  bool get hasFailedMessages => messages.any((m) => m.status == MessageStatus.failed);

  @override
  List<Object> get props => [messages, threadId];
}

/// Error al cargar mensajes.
final class ChatError extends ChatState {
  const ChatError({required this.message});

  final String message;

  @override
  List<Object> get props => [message];
}
