// Pantalla de registro de usuario.
//
// Es la primera pantalla que ve el usuario al instalar la app.
// Solo pide un nombre — sin email, password ni datos adicionales.
//
// FLUJO:
//   1. Usuario ingresa su nombre
//   2. Toca "Comenzar"
//   3. UserBloc.CreateUserEvent → guarda local + outbox
//   4. UserLoaded → Navigator reemplaza esta pantalla con ThreadsScreen
//
// OFFLINE:
//   El registro funciona completamente offline. El usuario puede
//   empezar a usar la app sin conexión — el outbox sincronizará
//   el registro con el servidor cuando haya red.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injector.dart';
import '../blocs/user/user_bloc.dart';
import 'threads_screen.dart';

class CreateUserScreen extends StatefulWidget {
  const CreateUserScreen({super.key});

  @override
  State<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends State<CreateUserScreen> {
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<UserBloc>(),
      child: Scaffold(
        body: SafeArea(
          child: BlocConsumer<UserBloc, UserState>(
            // BlocListener: reacciona a cambios de estado con side effects
            // (navegación, snackbars). No reconstruye el widget.
            listener: (context, state) {
              if (state is UserLoaded) {
                // Reemplazar la pantalla — el usuario no debe poder
                // volver atrás al registro con el botón back.
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ThreadsScreen()));
              }
              if (state is UserError) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(state.message), backgroundColor: Colors.red.shade700));
              }
            },
            // BlocBuilder: reconstruye el widget según el estado actual.
            builder: (context, state) {
              final isLoading = state is UserLoading;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Ícono / Logo ──────────────────────────────────
                      const Icon(Icons.chat_bubble_rounded, size: 72, color: Colors.blue),
                      const SizedBox(height: 24),

                      // ── Título ────────────────────────────────────────
                      Text(
                        'ChatSync',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ingresa tu nombre para comenzar',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                      ),
                      const SizedBox(height: 40),

                      // ── Campo de nombre ───────────────────────────────
                      TextFormField(
                        controller: _nameController,
                        enabled: !isLoading,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: 'Tu nombre',
                          hintText: 'Ej: María García',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final trimmed = value?.trim() ?? '';
                          if (trimmed.isEmpty) {
                            return 'El nombre no puede estar vacío';
                          }
                          if (trimmed.length < 2) {
                            return 'El nombre debe tener al menos 2 caracteres';
                          }
                          return null;
                        },
                        // Enviar al presionar "done" en el teclado
                        onFieldSubmitted: (_) => _submit(context),
                      ),
                      const SizedBox(height: 24),

                      // ── Botón de registro ─────────────────────────────
                      FilledButton(
                        onPressed: isLoading ? null : () => _submit(context),
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        child: isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Comenzar', style: TextStyle(fontSize: 16)),
                      ),
                      const SizedBox(height: 16),

                      // ── Nota offline ──────────────────────────────────
                      // Informa al usuario que puede usar la app sin red
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.offline_bolt_outlined, size: 14, color: Colors.grey.shade500),
                          const SizedBox(width: 4),
                          Text(
                            'Funciona sin conexión a internet',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Valida el formulario y despacha el evento de creación.
  void _submit(BuildContext context) {
    if (_formKey.currentState?.validate() ?? false) {
      context.read<UserBloc>().add(CreateUserEvent(name: _nameController.text));
    }
  }
}
