part of 'user_bloc.dart';

/// Estados del UserBloc.
sealed class UserState extends Equatable {
  const UserState();

  @override
  List<Object> get props => [];
}

/// Estado inicial antes de verificar sesión.
/// La UI muestra un splash o indicador de carga.
final class UserInitial extends UserState {
  const UserInitial();
}

/// Verificando o creando usuario — operación en progreso.
/// La UI deshabilita el botón de registro y muestra un loader.
final class UserLoading extends UserState {
  const UserLoading();
}

/// Usuario cargado exitosamente (existente o recién creado).
/// La UI navega a ThreadsScreen.
final class UserLoaded extends UserState {
  const UserLoaded({required this.user});

  final UserEntity user;

  @override
  List<Object> get props => [user];
}

/// No hay usuario registrado en este dispositivo.
/// La UI navega a CreateUserScreen.
final class UserNotFound extends UserState {
  const UserNotFound();
}

/// Error al crear o cargar el usuario.
/// [message] descripción legible para mostrar en la UI.
final class UserError extends UserState {
  const UserError({required this.message});

  final String message;

  @override
  List<Object> get props => [message];
}
