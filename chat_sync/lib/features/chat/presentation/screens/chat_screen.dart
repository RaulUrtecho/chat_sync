// Pantalla de conversación — el corazón visual del proyecto.
//
// DEMOSTRACIÓN OFFLINE:
//   Esta pantalla es donde se puede observar y testear todo el
//   soporte offline en acción:
//
//   1. Escribir mensajes sin red → aparecen con ⏱ (pending)
//   2. Restaurar la red → los ⏱ cambian a ✓ (sent) automáticamente
//   3. Servidor apagado N veces → mensajes cambian a ✗ (failed)
//   4. Tocar ✗ → "Reintentar" → vuelve a ⏱ → sincroniza
//
// REACTIVIDAD:
//   ChatBloc usa emit.forEach sobre watchMessages() de Drift.
//   Cada cambio en la DB (sea por outbox, WebSocket, o delta sync)
//   reconstruye la lista automáticamente — cero polling.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injector.dart';
import '../../../../core/network/connectivity_monitor.dart';
import '../../domain/entities/message_entity.dart';
import '../blocs/chat/chat_bloc.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.threadId, required this.participantName});

  final String threadId;
  final String participantName;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<ChatBloc>()..add(LoadMessagesEvent(threadId: widget.threadId)),
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              // Avatar del contacto
              CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  widget.participantName[0].toUpperCase(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.participantName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  // Indicador de estado de sync en el subtítulo
                  BlocBuilder<ChatBloc, ChatState>(
                    buildWhen: (prev, curr) =>
                        prev.runtimeType != curr.runtimeType ||
                        (curr is ChatLoaded &&
                            prev is ChatLoaded &&
                            curr.hasPendingMessages != prev.hasPendingMessages),
                    builder: (context, state) {
                      if (state is ChatLoaded && state.hasPendingMessages) {
                        return const Text('Sincronizando...', style: TextStyle(fontSize: 11, color: Colors.grey));
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            // Banner de conectividad
            ConnectivityBanner(monitor: getIt<ConnectivityMonitor>()),

            // Lista de mensajes
            Expanded(
              child: BlocConsumer<ChatBloc, ChatState>(
                listener: (context, state) {
                  // Auto-scroll al fondo cuando llega un nuevo mensaje
                  if (state is ChatLoaded) {
                    _scrollToBottom();
                  }
                },
                builder: (context, state) {
                  return switch (state) {
                    ChatInitial() || ChatLoading() => const Center(child: CircularProgressIndicator()),

                    ChatLoaded(:final messages) =>
                      messages.isEmpty
                          ? const _EmptyChat()
                          : _MessageList(messages: messages, scrollController: _scrollController),

                    ChatError(:final message) => Center(
                      child: Text(message, style: const TextStyle(color: Colors.red)),
                    ),
                  };
                },
              ),
            ),

            // Input de mensaje
            _MessageInput(controller: _messageController),
          ],
        ),
      ),
    );
  }

  /// Hace scroll al último mensaje con animación suave.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGETS PRIVADOS
// ─────────────────────────────────────────────────────────────────────────────

/// Lista de burbujas de mensajes.
class _MessageList extends StatelessWidget {
  const _MessageList({required this.messages, required this.scrollController});

  final List<MessageEntity> messages;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final prevMessage = index > 0 ? messages[index - 1] : null;

        // Mostrar separador de fecha si cambió el día
        final showDateSeparator = prevMessage == null || !_isSameDay(prevMessage.createdAt, message.createdAt);

        return Column(
          children: [
            if (showDateSeparator) _DateSeparator(date: message.createdAt),
            MessageBubble(
              message: message,
              onRetry: message.isFailed
                  ? () => context.read<ChatBloc>().add(RetryMessageEvent(messageId: message.id))
                  : null,
            ),
          ],
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Separador visual de fecha entre mensajes de días distintos.
class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    String label;

    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      label = 'Hoy';
    } else if (date.year == now.year && date.month == now.month && date.day == now.day - 1) {
      label = 'Ayer';
    } else {
      label = '${date.day}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Campo de texto para escribir y enviar mensajes.
class _MessageInput extends StatelessWidget {
  const _MessageInput({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Colors.grey.shade200)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Campo de texto
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Escribe un mensaje...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Botón de enviar
            // Usa ValueListenableBuilder para activar/desactivar
            // el botón según si hay texto en el campo.
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return AnimatedScale(
                  scale: hasText ? 1.0 : 0.8,
                  duration: const Duration(milliseconds: 150),
                  child: FloatingActionButton.small(
                    onPressed: hasText ? () => _send(context) : null,
                    elevation: 0,
                    child: const Icon(Icons.send_rounded, size: 20),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _send(BuildContext context) {
    final text = controller.text.trim();
    if (text.isEmpty) return;

    // Despachar el evento de envío
    // El BLoC no necesita saber el threadId aquí — lo tiene internamente
    context.read<ChatBloc>().add(SendMessageEvent(content: text));

    // Limpiar el campo inmediatamente (Optimistic UI)
    controller.clear();
  }
}

/// Pantalla vacía cuando no hay mensajes aún.
class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            'Sin mensajes aún\nSé el primero en escribir',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}
