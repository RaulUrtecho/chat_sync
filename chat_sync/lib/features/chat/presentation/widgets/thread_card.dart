// Card de conversación en la lista de threads.
//
// Muestra:
//   · Avatar con inicial del contacto
//   · Nombre del contacto
//   · Último mensaje (truncado a 1 línea)
//   · Timestamp del último mensaje
//   · Indicador de sync pendiente si el thread no está sincronizado

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/entities/thread_entity.dart';

class ThreadCard extends StatelessWidget {
  const ThreadCard({super.key, required this.thread, required this.onTap});

  final ThreadEntity thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),

      // ── Avatar con inicial ─────────────────────────────────────────────
      leading: CircleAvatar(
        radius: 26,
        backgroundColor: colorScheme.primaryContainer,
        child: Text(
          thread.participant.name[0].toUpperCase(),
          style: TextStyle(color: colorScheme.onPrimaryContainer, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),

      // ── Nombre del contacto ────────────────────────────────────────────
      title: Row(
        children: [
          Expanded(
            child: Text(
              thread.participant.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Timestamp del último mensaje
          if (thread.lastMessageAt != null)
            Text(_formatTimestamp(thread.lastMessageAt!), style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ],
      ),

      // ── Último mensaje ─────────────────────────────────────────────────
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              thread.lastMessage ?? 'Sin mensajes aún',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: thread.lastMessage != null ? Colors.grey.shade700 : Colors.grey.shade400,
                fontSize: 13,
              ),
            ),
          ),

          // Indicador de thread pendiente de sincronización
          // Muestra un ícono de reloj si el thread aún no llegó al servidor
          if (thread.isPending)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.schedule, size: 14, color: Colors.grey.shade400),
            ),
        ],
      ),
    );
  }

  /// Formatea el timestamp para mostrarlo de forma compacta.
  ///
  /// · Hoy      → "14:30"
  /// · Esta semana → "lun", "mar", etc.
  /// · Más antiguo  → "15/01"
  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(msgDay).inDays;

    if (diff == 0) return DateFormat('HH:mm').format(dt);
    if (diff < 7) return DateFormat('EEE', 'es').format(dt);
    return DateFormat('dd/MM').format(dt);
  }
}
