part of 'chat_bloc.dart';

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object> get props => [];
}

/// Carga mensajes de un thread y suscribe al stream de cambios.
/// Se dispara cuando ChatScreen se monta.
final class LoadMessagesEvent extends ChatEvent {
  const LoadMessagesEvent({required this.threadId});

  final String threadId;

  @override
  List<Object> get props => [threadId];
}

/// El usuario tocó el botón de enviar.
/// [content] texto del mensaje a enviar.
final class SendMessageEvent extends ChatEvent {
  const SendMessageEvent({required this.content});

  final String content;

  @override
  List<Object> get props => [content];
}

/// El usuario quiere reintentar un mensaje fallido (status: failed ✗).
/// [messageId] ID del mensaje a reintentar.
final class RetryMessageEvent extends ChatEvent {
  const RetryMessageEvent({required this.messageId});

  final String messageId;

  @override
  List<Object> get props => [messageId];
}
