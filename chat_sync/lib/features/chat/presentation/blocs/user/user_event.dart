part of 'user_bloc.dart';

/// Eventos del UserBloc.
///
/// [sealed] garantiza que solo los subtipos definidos en este archivo
/// son válidos — el compilador verifica exhaustividad en switch.
sealed class UserEvent extends Equatable {
  const UserEvent();

  @override
  List<Object> get props => [];
}

/// Verifica si ya existe un usuario registrado en este dispositivo.
///
/// Se dispara al abrir la app. Si hay usuario → UserLoaded.
/// Si no → UserNotFound → mostrar CreateUserScreen.
final class CheckCurrentUserEvent extends UserEvent {
  const CheckCurrentUserEvent();
}

/// El usuario completó el formulario y quiere registrarse.
///
/// [name] nombre ingresado en CreateUserScreen.
final class CreateUserEvent extends UserEvent {
  const CreateUserEvent({required this.name});

  final String name;

  @override
  List<Object> get props => [name];
}
