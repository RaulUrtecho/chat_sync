// Entidad de dominio: Thread (conversación).
//
// Un thread representa la conversación entre el usuario actual y un contacto.
// Contiene la metadata necesaria para renderizar una thread card en la UI
// sin necesidad de JOINs adicionales.

import 'package:equatable/equatable.dart';

import 'user_entity.dart';

/// Representa una conversación (thread) en la lista de chats.
class ThreadEntity extends Equatable {
  const ThreadEntity({
    required this.id,
    required this.participant,
    required this.syncStatus,
    required this.createdAt,
    this.lastMessage,
    this.lastMessageAt,
  });

  final String id;

  /// El contacto con quien se tiene esta conversación.
  ///
  /// Se incluye el objeto completo (no solo el ID) para que la UI
  /// pueda mostrar el nombre sin queries adicionales.
  final UserEntity participant;

  /// Último mensaje del thread (puede ser null si no hay mensajes aún).
  final String? lastMessage;

  /// Timestamp del último mensaje (para ordenar threads por actividad).
  final DateTime? lastMessageAt;

  /// Estado de sincronización con el servidor.
  /// 'pending' | 'synced'
  final String syncStatus;

  final DateTime createdAt;

  /// Retorna true si el thread aún no se ha sincronizado con el servidor.
  bool get isPending => syncStatus == 'pending';

  @override
  List<Object?> get props => [id, participant, lastMessage, lastMessageAt, syncStatus, createdAt];

  @override
  String toString() => 'ThreadEntity(id: $id, participant: ${participant.name})';
}
