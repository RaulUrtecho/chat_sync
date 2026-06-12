// Pantalla principal — lista de conversaciones y búsqueda de usuarios.
//
// ESTRUCTURA:
//   AppBar con SearchBar integrado
//   Body:
//     · Sin búsqueda activa → lista de ThreadCards
//     · Con búsqueda activa → lista de resultados de usuarios
//
// INDICADOR DE CONECTIVIDAD:
//   Un banner sutil en la parte superior indica cuando la app
//   está offline o en estado degradado. Desaparece al reconectar.
//
// REACTIVIDAD:
//   ThreadsBloc.LoadThreadsEvent → emit.forEach sobre watchThreads()
//   Cada cambio en la DB (nuevo mensaje, sync completado) actualiza
//   la lista automáticamente sin ningún pull-to-refresh.

import 'package:chat_sync/core/notifications/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injector.dart';
import '../../../../core/network/connectivity_monitor.dart';
import '../blocs/threads/threads_bloc.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/thread_card.dart';
import 'chat_screen.dart';

class ThreadsScreen extends StatefulWidget {
  const ThreadsScreen({super.key});

  @override
  State<ThreadsScreen> createState() => _ThreadsScreenState();
}

class _ThreadsScreenState extends State<ThreadsScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    // Verificar si hay navegación pendiente desde una notificación
    // cuando la app estaba cerrada
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = NotificationService.instance.pendingThreadId;
      if (pending != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              threadId: pending,
              participantName: NotificationService.instance.pendingSenderName ?? 'Chat',
            ),
          ),
        );
        NotificationService.instance.clearPending();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<ThreadsBloc>()..add(const LoadThreadsEvent()),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chats'),
          centerTitle: false,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: _SearchBar(controller: _searchController, focusNode: _searchFocusNode),
          ),
        ),
        body: Column(
          children: [
            // Banner de conectividad — visible solo cuando no hay red
            ConnectivityBanner(monitor: getIt<ConnectivityMonitor>()),

            // Contenido principal
            Expanded(
              child: BlocConsumer<ThreadsBloc, ThreadsState>(
                listenWhen: (previous, current) => current.command != null && current.command != previous.command,
                listener: (context, state) {
                  final command = state.command;
                  if (command is NavigateToThreadCommand) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatScreen(threadId: command.threadId, participantName: command.participantName),
                      ),
                    );
                  }
                },
                builder: (context, state) {
                  return switch (state.status) {
                    // ── Carga inicial ──────────────────────────────────
                    ThreadsStatus.initial || ThreadsStatus.loading => const Center(child: CircularProgressIndicator()),

                    // ── Lista de threads ───────────────────────────────
                    ThreadsStatus.loaded =>
                      state.threads.isEmpty
                          ? _EmptyThreads(onSearch: () => _searchFocusNode.requestFocus())
                          : ListView.separated(
                              itemCount: state.threads.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                              itemBuilder: (context, index) {
                                final thread = state.threads[index];
                                return ThreadCard(
                                  thread: thread,
                                  onTap: () =>
                                      context.read<ThreadsBloc>().add(SelectUserEvent(participant: thread.participant)),
                                );
                              },
                            ),

                    // ── Resultados de búsqueda ─────────────────────────
                    ThreadsStatus.searching => _SearchResults(
                      query: state.searchQuery,
                      results: state.searchResults,
                      isSearching: state.isSearching,
                    ),

                    // ── Error ──────────────────────────────────────────
                    ThreadsStatus.error => Center(
                      child: Text(state.error, style: const TextStyle(color: Colors.red)),
                    ),
                  };
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGETS PRIVADOS
// ─────────────────────────────────────────────────────────────────────────────

/// Search bar integrado en el AppBar.
///
/// Despacha SearchUsersEvent en cada cambio de texto con un pequeño
/// debounce implícito gracias al TextField (solo despacha en onChange).
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Buscar usuarios...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: ValueListenableBuilder(
            valueListenable: controller,
            builder: (_, value, _) => value.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      controller.clear();
                      context.read<ThreadsBloc>().add(const SearchUsersEvent(query: ''));
                    },
                  )
                : const SizedBox.shrink(),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        onChanged: (query) => context.read<ThreadsBloc>().add(SearchUsersEvent(query: query)),
      ),
    );
  }
}

/// Lista de resultados de búsqueda de usuarios.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query, required this.results, required this.isSearching});

  final String query;
  final List results;
  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    if (isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text('Sin resultados para "$query"', style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final user = results[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.blue.shade100,
            child: Text(
              user.name[0].toUpperCase(),
              style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(user.name),
          subtitle: const Text('Toca para iniciar chat'),
          onTap: () => context.read<ThreadsBloc>().add(SelectUserEvent(participant: user)),
        );
      },
    );
  }
}

/// Pantalla vacía cuando no hay conversaciones aún.
class _EmptyThreads extends StatelessWidget {
  const _EmptyThreads({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Sin conversaciones aún',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text('Busca un usuario para comenzar a chatear', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: onSearch,
            icon: const Icon(Icons.search),
            label: const Text('Buscar usuarios'),
          ),
        ],
      ),
    );
  }
}
