import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../data/chat_repository.dart';
import '../../../domain/entities/thread_entity.dart';
import '../../../domain/entities/user_entity.dart';

part 'threads_command.dart';
part 'threads_event.dart';
part 'threads_state.dart';

/// Gestión de la lista de conversaciones y búsqueda de usuarios.
class ThreadsBloc extends Bloc<ThreadsEvent, ThreadsState> {
  ThreadsBloc({required ChatRepository repository}) : _repository = repository, super(const ThreadsState()) {
    on<LoadThreadsEvent>(_onLoadThreads);
    on<SearchUsersEvent>(_onSearchUsers);
    on<SelectUserEvent>(_onSelectUser);
  }

  final ChatRepository _repository;

  // ---------------------------------------------------------------------------
  // HANDLERS
  // ---------------------------------------------------------------------------

  Future<void> _onLoadThreads(LoadThreadsEvent event, Emitter<ThreadsState> emit) async {
    emit(state.copyWith(status: ThreadsStatus.loading));
    _repository.fetchAndCacheThreads(); // fire and forget
    await emit.forEach<List<ThreadEntity>>(
      _repository.watchThreads(),
      onData: (threads) => state.copyWith(status: ThreadsStatus.loaded, threads: threads),
      onError: (_, _) => state.copyWith(status: ThreadsStatus.error, error: 'Error al cargar conversaciones'),
    );
  }

  Future<void> _onSearchUsers(SearchUsersEvent event, Emitter<ThreadsState> emit) async {
    final query = event.query.trim();

    if (query.isEmpty) {
      add(const LoadThreadsEvent());
      return;
    }

    emit(
      state.copyWith(status: ThreadsStatus.searching, searchQuery: query, searchResults: const [], isSearching: true),
    );

    try {
      final users = await _repository.searchUsers(query);
      final currentUser = await _repository.getCurrentUser();
      final filtered = users.where((u) => u.id != currentUser?.id).toList();
      emit(state.copyWith(searchResults: filtered, isSearching: false));
    } catch (_) {
      emit(state.copyWith(searchResults: const [], isSearching: false));
    }
  }

  /// Crea o recupera el thread y emite el command de navegación en el estado.
  /// No cambia status — la lista permanece visible mientras se navega.
  Future<void> _onSelectUser(SelectUserEvent event, Emitter<ThreadsState> emit) async {
    try {
      final thread = await _repository.getOrCreateThread(event.participant);
      emit(
        state.copyWith(
          command: NavigateToThreadCommand(threadId: thread.id, participantName: event.participant.name),
        ),
      );
      emit(state.copyWith(command: null));
    } catch (e) {
      emit(state.copyWith(status: ThreadsStatus.error, error: 'Error al abrir conversación: $e'));
    }
  }
}
