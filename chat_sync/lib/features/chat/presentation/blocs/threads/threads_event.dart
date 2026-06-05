part of 'threads_bloc.dart';

sealed class ThreadsEvent extends Equatable {
  const ThreadsEvent();

  @override
  List<Object> get props => [];
}

/// Inicia la suscripción reactiva al stream de threads.
/// Se dispara cuando ThreadsScreen se monta.
final class LoadThreadsEvent extends ThreadsEvent {
  const LoadThreadsEvent();
}

/// El usuario escribió en el search bar.
///
/// [query] texto actual. Si está vacío, volver a la lista de threads.
final class SearchUsersEvent extends ThreadsEvent {
  const SearchUsersEvent({required this.query});

  final String query;

  @override
  List<Object> get props => [query];
}

/// El usuario seleccionó un contacto de los resultados de búsqueda.
///
/// El BLoC creará o recuperará el thread y emitirá ThreadSelectedState
/// para que la UI navegue al ChatScreen.
final class SelectUserEvent extends ThreadsEvent {
  const SelectUserEvent({required this.participant});

  final UserEntity participant;

  @override
  List<Object> get props => [participant];
}
