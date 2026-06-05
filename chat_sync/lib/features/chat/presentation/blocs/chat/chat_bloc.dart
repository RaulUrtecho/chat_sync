import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../data/chat_repository.dart';
import '../../../domain/entities/message_entity.dart';

part 'chat_event.dart';
part 'chat_state.dart';

/// Gestión del ciclo de vida completo del chat offline-first.
///
/// ENVÍO CON OPTIMISTIC UI:
///   SendMessageEvent
///       ↓
///   repository.sendMessage() → inserta localmente con 'pending'
///       ↓
///   Drift emite en watchMessages() automáticamente
///       ↓
///   emit.forEach genera ChatLoaded con mensaje ⏱
///       ↓
///   OutboxWorker sincroniza en background
///       ↓
///   Drift emite con 'sent' ✓ o 'failed' ✗ → UI se actualiza sola
///
/// NOTA: ChatBloc NO emite estado después de sendMessage.
/// El stream reactivo de Drift propaga el cambio automáticamente.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({required ChatRepository repository}) : _repository = repository, super(const ChatInitial()) {
    on<LoadMessagesEvent>(_onLoadMessages);
    on<SendMessageEvent>(_onSendMessage);
    on<RetryMessageEvent>(_onRetryMessage);
  }

  final ChatRepository _repository;

  /// Thread activo — establecido en LoadMessagesEvent,
  /// usado por SendMessageEvent para saber a qué thread enviar.
  String? _activeThreadId;

  // ---------------------------------------------------------------------------
  // HANDLERS
  // ---------------------------------------------------------------------------

  /// Suscribe al stream reactivo de mensajes del thread.
  ///
  /// emit.forEach mantiene la suscripción viva mientras el BLoC existe.
  /// Cada emisión de Drift genera un nuevo ChatLoaded automáticamente.
  Future<void> _onLoadMessages(LoadMessagesEvent event, Emitter<ChatState> emit) async {
    _activeThreadId = event.threadId;
    emit(const ChatLoading());

    await emit.forEach<List<MessageEntity>>(
      _repository.watchMessages(event.threadId),
      onData: (messages) => ChatLoaded(messages: messages, threadId: event.threadId),
      onError: (_, _) => const ChatError(message: 'Error al cargar mensajes'),
    );
  }

  /// Envía un mensaje nuevo con Optimistic UI.
  ///
  /// No emite estado directamente — el stream reactivo de Drift
  /// lo propagará automáticamente vía _onLoadMessages.
  Future<void> _onSendMessage(SendMessageEvent event, Emitter<ChatState> emit) async {
    final threadId = _activeThreadId;
    if (threadId == null) return;

    final content = event.content.trim();
    if (content.isEmpty) return;

    // Guarda localmente + encola en outbox (transacción atómica)
    // Drift notificará el cambio → emit.forEach emitirá ChatLoaded
    await _repository.sendMessage(threadId: threadId, content: content);
  }

  /// Reintenta un mensaje con status 'failed'.
  ///
  /// Resetea a 'pending' y re-encola en outbox.
  /// Drift propagará el cambio de status automáticamente.
  Future<void> _onRetryMessage(RetryMessageEvent event, Emitter<ChatState> emit) async {
    await _repository.retryFailedMessage(event.messageId);
  }
}
