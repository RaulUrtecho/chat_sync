part of 'threads_bloc.dart';

sealed class ThreadsCommand {
  const ThreadsCommand();
}

final class NavigateToThreadCommand extends ThreadsCommand {
  const NavigateToThreadCommand({required this.threadId, required this.participantName});

  final String threadId;
  final String participantName;
}
