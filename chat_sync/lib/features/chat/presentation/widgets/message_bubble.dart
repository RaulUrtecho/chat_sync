// Burbuja de mensaje — el widget más importante de la UI offline.
//
// INDICADORES DE ESTADO (solo en mensajes propios):
//   ⏱ pending  → reloj gris    — guardado local, esperando sync
//   ✓ sent     → check azul    — confirmado por el servidor
//   ✗ failed   → error rojo    — falló tras N reintentos
//
// Los mensajes recibidos (del contacto) no muestran indicador de estado.
//
// RETRY:
//   Los mensajes con status 'failed' muestran un botón "Reintentar"
//   al hacer long press o al tocar el ícono de error.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/entities/message_entity.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, this.onRetry});

  final MessageEntity message;

  /// Callback para reintentar mensajes fallidos.
  /// Si es null, el mensaje no es reintentable (no está fallido).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isOwn = message.isFromCurrentUser;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isOwn ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // Long press en mensajes fallidos → menú de reintentar
        onLongPress: message.isFailed ? onRetry : null,
        child: Container(
          margin: EdgeInsets.only(top: 2, bottom: 2, left: isOwn ? 64 : 0, right: isOwn ? 0 : 64),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isOwn ? colorScheme.primary : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isOwn ? 18 : 4),
              bottomRight: Radius.circular(isOwn ? 4 : 18),
            ),
            // Borde rojo sutil en mensajes fallidos
            border: message.isFailed ? Border.all(color: Colors.red.shade300, width: 1.5) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Contenido del mensaje ──────────────────────────────
              Text(
                message.content,
                style: TextStyle(color: isOwn ? colorScheme.onPrimary : colorScheme.onSurface, fontSize: 15),
              ),
              const SizedBox(height: 4),

              // ── Timestamp + indicador de estado ───────────────────
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormat('HH:mm').format(message.createdAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: isOwn ? colorScheme.onPrimary.withValues(alpha: 0.7) : Colors.grey.shade500,
                    ),
                  ),

                  // Indicador de estado — solo en mensajes propios
                  if (isOwn) ...[const SizedBox(width: 4), _StatusIndicator(status: message.status, onRetry: onRetry)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ícono de estado del mensaje.
///
/// · pending  → ⏱ reloj gris animado
/// · sent     → ✓ check azul claro
/// · failed   → ✗ error rojo con botón de retry
/// · received → no se muestra (no es mensaje propio)
class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({required this.status, this.onRetry});

  final MessageStatus status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      // ⏱ Pending — reloj gris, indica que está en cola para enviar
      MessageStatus.pending => const Icon(Icons.access_time, size: 12, color: Colors.white54),

      // ✓ Sent — check azul, confirmado por el servidor
      MessageStatus.sent => const Icon(Icons.done_all, size: 14, color: Colors.white70),

      // ✗ Failed — error rojo, tappable para reintentar
      MessageStatus.failed => GestureDetector(
        onTap: onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 14, color: Colors.red.shade300),
            const SizedBox(width: 2),
            Text(
              'Reintentar',
              style: TextStyle(
                fontSize: 10,
                color: Colors.red.shade300,
                decoration: TextDecoration.underline,
                decorationColor: Colors.red.shade300,
              ),
            ),
          ],
        ),
      ),

      // received — no aplica para mensajes propios, no mostrar
      MessageStatus.received => const SizedBox.shrink(),
    };
  }
}
