import 'package:bloc/bloc.dart';
import 'package:chat_sync/core/notifications/notification_service.dart';
import 'package:equatable/equatable.dart';
import '../../../../../core/di/injector.dart';
import '../../../data/chat_repository.dart';
import '../../../domain/entities/user_entity.dart';

part 'user_event.dart';
part 'user_state.dart';

/// Gestión del usuario actual: verificar sesión y registrar usuario nuevo.
class UserBloc extends Bloc<UserEvent, UserState> {
  UserBloc({required ChatRepository repository}) : _repository = repository, super(const UserInitial()) {
    on<CheckCurrentUserEvent>(_onCheckCurrentUser);
    on<CreateUserEvent>(_onCreateUser);
  }

  final ChatRepository _repository;

  // ---------------------------------------------------------------------------
  // HANDLERS
  // ---------------------------------------------------------------------------

  /// Verifica si ya existe un usuario guardado localmente.
  ///
  /// Si existe  → inicia workers y emite UserLoaded.
  /// Si no existe → emite UserNotFound para mostrar CreateUserScreen.
  Future<void> _onCheckCurrentUser(CheckCurrentUserEvent event, Emitter<UserState> emit) async {
    emit(const UserLoading());
    try {
      final user = await _repository.getCurrentUser();
      if (user != null) {
        startWorkersAfterLogin(user.id);

        // Registrar FCM token en el servidor
        final fcmToken = await NotificationService.instance.getToken();
        if (fcmToken != null) {
          await _repository.updateFCMToken(fcmToken);
        }

        // Suscribirse al refresh automático del token
        // FCM puede rotar el token en cualquier momento sin aviso
        NotificationService.instance.onTokenRefresh.listen((newToken) {
          _repository.updateFCMToken(newToken);
        });

        emit(UserLoaded(user: user));
      } else {
        emit(const UserNotFound());
      }
    } catch (e) {
      emit(UserError(message: 'Error al cargar sesión: $e'));
    }
  }

  /// Crea un nuevo usuario con el nombre ingresado.
  ///
  /// FLUJO:
  ///   1. Validar nombre
  ///   2. Crear en Repository (local + outbox)
  ///   3. Iniciar workers con el nuevo userId
  ///   4. Emitir UserLoaded → UI navega a ThreadsScreen
  Future<void> _onCreateUser(CreateUserEvent event, Emitter<UserState> emit) async {
    final trimmedName = event.name.trim();

    if (trimmedName.isEmpty) {
      emit(const UserError(message: 'El nombre no puede estar vacío'));
      return;
    }
    if (trimmedName.length < 2) {
      emit(const UserError(message: 'El nombre debe tener al menos 2 caracteres'));
      return;
    }

    emit(const UserLoading());
    try {
      final user = await _repository.createUser(trimmedName);
      startWorkersAfterLogin(user.id);

      // Registrar FCM token en el servidor
      final fcmToken = await NotificationService.instance.getToken();
      if (fcmToken != null) {
        await _repository.updateFCMToken(fcmToken);
      }

      // Suscribirse al refresh automático del token
      NotificationService.instance.onTokenRefresh.listen((newToken) {
        _repository.updateFCMToken(newToken);
      });

      emit(UserLoaded(user: user));
    } catch (e) {
      emit(UserError(message: 'Error al crear usuario: $e'));
    }
  }
}
