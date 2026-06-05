part of 'threads_bloc.dart';

enum ThreadsStatus { initial, loading, loaded, error, searching }

final class ThreadsState extends Equatable {
  const ThreadsState({
    this.status = ThreadsStatus.initial,
    this.threads = const [],
    this.searchQuery = '',
    this.searchResults = const [],
    this.isSearching = false,
    this.error = '',
    this.command,
  });

  final ThreadsStatus status;
  final List<ThreadEntity> threads;
  final String searchQuery;
  final List<UserEntity> searchResults;
  final bool isSearching;
  final String error;
  final ThreadsCommand? command;

  // Centinela para poder pasar null explícito al campo nullable command
  // 1. No pasas command → se conserva el actual
  // 2. Pasas null → se limpia
  // 3. Pasas un valor → se asigna ese valor
  static const _absent = Object();

  ThreadsState copyWith({
    ThreadsStatus? status,
    List<ThreadEntity>? threads,
    String? searchQuery,
    List<UserEntity>? searchResults,
    bool? isSearching,
    String? error,
    Object? command = _absent,
  }) {
    return ThreadsState(
      status: status ?? this.status,
      threads: threads ?? this.threads,
      searchQuery: searchQuery ?? this.searchQuery,
      searchResults: searchResults ?? this.searchResults,
      isSearching: isSearching ?? this.isSearching,
      error: error ?? this.error,
      // identical compara identidad de objeto (mismo puntero en memoria),
      // no igualdad de valor.
      // Con static const, Dart garantiza que hay exactamente una instancia de _absent
      // en toda la app, así la comparación siempre funciona correctamente.
      command: identical(command, _absent) ? this.command : command as ThreadsCommand?,
    );
  }

  @override
  List<Object?> get props => [status, threads, searchQuery, searchResults, isSearching, error, command];
}
