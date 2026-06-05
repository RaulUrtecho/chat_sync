# 📱 ChatSync — Flutter App

Cliente móvil offline-first para iOS y Android.  
Stack: Flutter · Drift · Dio · BLoC · get_it

---

## 🏗️ Arquitectura

### Principio central: Offline-First

```
        ┌──────────────────────────────────┐
        │              UI                  │
        │   (siempre lee desde local DB)   │
        └───────────────┬──────────────────┘
                        │
        ┌───────────────▼──────────────────┐
        │          Repository              │
        │  · Escribe en local DB primero   │
        │  · Encola en Outbox              │
        │  · Sincroniza en background      │
        └──────────┬─────────────┬─────────┘
                   │             │
      ┌────────────▼──┐    ┌─────▼──────────────┐
      │   Local DB    │    │    Remote API       │
      │  (Drift/SQLite)│   │  (Go + Gin +        │
      │               │    │   WebSocket)        │
      └───────────────┘    └─────────────────────┘
```

### Estructura de carpetas

```
lib/
├── core/
│   ├── database/
│   │   ├── app_database.dart          # Ensamble Drift + migraciones
│   │   ├── tables/
│   │   │   ├── users_table.dart
│   │   │   ├── threads_table.dart
│   │   │   ├── messages_table.dart
│   │   │   └── outbox_table.dart      # Cola offline ⭐
│   │   └── daos/
│   │       ├── users_dao.dart
│   │       ├── threads_dao.dart
│   │       ├── messages_dao.dart
│   │       └── outbox_dao.dart
│   ├── network/
│   │   ├── connectivity_monitor.dart  # Two-signal pattern ⭐
│   │   ├── dio_client.dart
│   │   └── interceptors/
│   │       ├── auth_interceptor.dart  # Inyecta X-User-Id
│   │       └── retry_interceptor.dart # Backoff exponencial
│   ├── sync/
│   │   ├── outbox_worker.dart         # Procesa cola offline ⭐
│   │   └── sync_engine.dart           # Delta sync + WebSocket ⭐
│   └── di/
│       └── injector.dart              # get_it + AppConfig
├── features/
│   └── chat/
│       ├── data/
│       │   ├── remote/chat_api.dart
│       │   ├── local/chat_local_ds.dart
│       │   └── chat_repository.dart   # Orquestación ⭐
│       ├── domain/
│       │   └── entities/
│       │       ├── user_entity.dart
│       │       ├── thread_entity.dart
│       │       └── message_entity.dart
│       └── presentation/
│           ├── blocs/
│           │   ├── user/              # user_bloc/event/state.dart
│           │   ├── threads/           # threads_bloc/event/state.dart
│           │   └── chat/              # chat_bloc/event/state.dart
│           ├── screens/
│           │   ├── create_user_screen.dart
│           │   ├── threads_screen.dart
│           │   └── chat_screen.dart
│           └── widgets/
│               ├── message_bubble.dart    # ⏱ ✓ ✗ status indicators
│               ├── thread_card.dart
│               └── connectivity_banner.dart
└── main.dart
```

---

## 📱 Pantallas y Flujo

```
CreateUserScreen    ← solo nombre, funciona offline
      ↓
ThreadsScreen       ← lista de conversaciones + search bar
      ↓
ChatScreen
  [msg] ⏱ pending  ← guardado local, en cola para enviar
  [msg] ✓ sent     ← confirmado por el servidor
  [msg] ✗ failed   → botón Reintentar
```

---

## 🧱 BLoCs

Todos usan `sealed class` + `final class` con `part of` — patrón de la extensión BLoC.

| BLoC | Eventos | Estados |
|------|---------|---------|
| `UserBloc` | `CheckCurrentUserEvent`, `CreateUserEvent` | `UserInitial`, `UserLoading`, `UserLoaded`, `UserNotFound`, `UserError` |
| `ThreadsBloc` | `LoadThreadsEvent`, `SearchUsersEvent`, `SelectUserEvent` | `ThreadsLoading`, `ThreadsLoaded`, `SearchResultsState`, `ThreadSelectedState`, `ThreadsError` |
| `ChatBloc` | `LoadMessagesEvent`, `SendMessageEvent`, `RetryMessageEvent` | `ChatInitial`, `ChatLoading`, `ChatLoaded`, `ChatError` |

---

## ⚙️ Levantar el Proyecto

```bash
# 1. Instalar dependencias
flutter pub get

# 2. Generar código Drift (OBLIGATORIO — sin esto no compila)
dart run build_runner build --delete-conflicting-outputs

# 3. Modo watch durante desarrollo activo
dart run build_runner watch --delete-conflicting-outputs

# 4. Correr la app
flutter run
```

### Configurar el servidor

Con VS Code `--dart-define` (recomendado):

```json
// .vscode/launch.json
{
  "configurations": [
    {
      "name": "Flutter (Emulator)",
      "type": "dart",
      "request": "launch",
      "args": ["--dart-define=SERVER_HOST=10.0.2.2"]
    },
    {
      "name": "Flutter (Physical Device)",
      "type": "dart",
      "request": "launch",
      "args": ["--dart-define=SERVER_HOST=192.168.1.74"]
    }
  ]
}
```

> `launch.json` está en `.gitignore` — cada desarrollador usa su propia IP.
> Commitear solo `.vscode/launch.json.example` como referencia.

### ¿Por qué el paso 2 (build_runner)?

Drift genera código a partir de las tablas y DAOs. Los archivos `.g.dart` no están en el
repo (`.gitignore`) y deben generarse localmente.

| Archivo generado | Contiene |
|-----------------|---------|
| `app_database.g.dart` | Ensamble principal, `_$AppDatabase` |
| `users_dao.g.dart` | `_$UsersDaoMixin` |
| `threads_dao.g.dart` | `_$ThreadsDaoMixin` |
| `messages_dao.g.dart` | `_$MessagesDaoMixin` |
| `outbox_dao.g.dart` | `_$OutboxDaoMixin` |

---

## 📦 Dependencias

| Paquete | Versión | Uso |
|---------|---------|-----|
| `drift` | ^2.x | ORM SQLite |
| `drift_flutter` | ^0.x | Integración Drift + Flutter |
| `sqlite3_flutter_libs` | ^0.5.x | Binarios SQLite nativos |
| `connectivity_plus` | ^6.x | Monitor de red |
| `dio` | ^5.x | HTTP client |
| `dio_smart_retry` | ^6.x | Retry con backoff |
| `flutter_bloc` | ^8.x | Gestión de estado |
| `bloc` | ^8.x | Core BLoC |
| `get_it` | ^8.x | Inyección de dependencias |
| `uuid` | ^4.x | UUID v4 en cliente |
| `shared_preferences` | ^2.x | Persistir userId |
| `equatable` | ^2.x | Comparación por valor |
| `intl` | ^0.19.x | Formateo de fechas |

---

## 📐 Decisiones de Diseño

**¿Por qué UUIDs en el cliente?**
Permite crear registros locales con ID final sin esperar respuesta del servidor.
Elimina la necesidad de reasignar IDs después de sincronizar.

**¿Por qué Drift sobre Hive o Isar?**
Drift usa SQLite con relaciones reales y queries tipadas. El outbox ordenado por `id`
autoincremental garantiza FIFO — no posible con stores key-value.

**¿Por qué BLoC?**
Los `sealed class` hacen que cada transición offline sea explícita y trazable.
Los streams de Drift se integran naturalmente con `emit.forEach`.

**¿Por qué el outbox en SQLite y no en memoria?**
Las operaciones pendientes deben sobrevivir al cierre de la app.

---

## 🔐 Seguridad — Encriptación de la DB Local

Para producción, encriptar con **SQLCipher (AES-256)**:

```dart
QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'chat_sync.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        final key = _getKeyFromSecureStorage(); // nunca hardcodeada
        db.execute("PRAGMA key = '$key'");
      },
    );
  });
}
```

Guardar la clave en `flutter_secure_storage` (Keychain/iOS, Keystore/Android).

---

## 🔄 Migraciones de Schema

Nunca modificar tablas directamente. Siempre incrementar `schemaVersion` y escribir en `onUpgrade`:

```dart
int get schemaVersion => 2;

onUpgrade: (m, from, to) async {
  if (from < 2) await m.addColumn(messages, messages.editedAt);
  if (from < 3) await m.createTable(reactions);
},
```

El patrón `if (from < N)` garantiza que migraciones intermedias se ejecuten en orden.