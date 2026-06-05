// Entidad de dominio: Usuario.
//
// Las entidades de dominio son clases puras de Dart — no dependen de
// Drift, Dio, ni ningún framework. Representan los conceptos del negocio
// tal como los entiende la app, independientemente de cómo se almacenan
// o transportan.
//
// DISTINCIÓN IMPORTANTE:
//   · User (este archivo) → entidad de dominio usada en BLoCs y UI
//   · User (generado por Drift) → DataClass de la tabla, usado en DAOs
//
//   El ChatRepository convierte entre ambos. Los BLoCs y la UI solo
//   conocen las entidades de dominio — nunca las clases de Drift.

import 'package:equatable/equatable.dart';

/// Representa un usuario del sistema de chat.
///
/// Extiende [Equatable] para comparación por valor:
///   User(id: '1', name: 'Ana') == User(id: '1', name: 'Ana') → true
///
/// Esto es esencial para BLoC: cuando el estado cambia, BLoC compara
/// el estado anterior con el nuevo. Sin Equatable, dos instancias con
/// los mismos datos serían "diferentes" y la UI se reconstruiría
/// innecesariamente en cada emisión.
class UserEntity extends Equatable {
  const UserEntity({required this.id, required this.name, required this.createdAt, this.isCurrentUser = false});

  final String id;
  final String name;
  final bool isCurrentUser;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, name, isCurrentUser, createdAt];

  @override
  String toString() => 'UserEntity(id: $id, name: $name)';
}
