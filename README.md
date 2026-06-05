# 💬 ChatSync — Offline-First Chat App

> Proyecto de aprendizaje enfocado en **soporte offline robusto** para aplicaciones móviles.
> Monorepo con cliente Flutter y backend Go + WebSocket.

---

## 🎯 Objetivo

Explorar y demostrar cómo construir una experiencia de mensajería que funcione **perfectamente
sin importar el estado de la red**. Los mensajes se envían al instante (visualmente), se encolan
si no hay conexión, y se sincronizan en orden cuando la red regresa.

**No es el objetivo:** auth compleja, multimedia, grupos, notificaciones push en producción.  
**Sí es el objetivo:** entender cada decisión de arquitectura offline-first.

---

## 🗂️ Estructura del Monorepo

```
chat_sync/
├── chat_sync_backend/       ← Go + Gin + PostgreSQL + WebSocket
│   └── README.md
├── chat_sync/               ← Flutter + Drift + BLoC
│   └── README.md
└── README.md                ← Este archivo
```

---

## 🧩 Patrones Implementados

### Outbox Pattern
Toda operación que requiere sync se escribe primero en una tabla local `outbox` antes de
intentar cualquier llamada HTTP. Un worker (`OutboxWorker`) procesa la cola en orden FIFO
cuando hay conexión.

```
Acción del usuario
    ↓
Escribe en tabla principal + outbox  ← misma transacción atómica
    ↓
UI se actualiza al instante
    ↓
OutboxWorker sincroniza en background cuando hay red
```

### Optimistic UI
El mensaje aparece en pantalla en el instante en que se escribe (`⏱ pending`). El estado
se actualiza reactivamente cuando el servidor confirma (`✓ sent`) o rechaza (`✗ failed`).

### Repository Pattern
Los BLoCs nunca acceden directamente a la DB ni a la red. Todo pasa por `ChatRepository`.

```
BLoC → ChatRepository → ChatLocalDs  → Drift (SQLite)
                      → ChatApi      → Dio (HTTP)
```

### Delta Sync
Al reconectar, solo se descarga lo que cambió usando un cursor `since`:
```
GET /messages/{threadId}?since=2024-01-15T10:30:00Z
```

### Idempotency Keys
Cada operación del outbox lleva `X-Idempotency-Key` (UUID del recurso). Si el cliente
reintenta tras un timeout, el servidor lo reconoce y no crea duplicados.

### BLoC Pattern
La UI despacha **eventos** y reacciona a **estados** (`sealed class`). El compilador
garantiza que todos los casos están manejados.

```
UI → add(Event) → BLoC → emit(State) → UI se reconstruye
```

### Reactive Streams (Drift + BLoC)
Drift expone los datos como `Stream<List<T>>`. Los BLoCs usan `emit.forEach` — cada
cambio en SQLite propaga automáticamente hasta la UI sin polling.

```
SQLite cambia → Drift emite → emit.forEach → nuevo State → UI reconstruye
```

### Connectivity Monitor (Two-Signal Pattern)
`connectivity_plus` detecta cambios de interfaz de red, y un ping HTTP real al servidor
confirma conectividad efectiva. Previene falsos positivos (portales cautivos, servidor caído).

---

## 🔄 Single Source of Truth + Unidirectional Data Flow

### SSOT — SQLite es la única fuente de verdad

La UI nunca lee de la API ni del WebSocket directamente.

```
Servidor remoto  ──►  SQLite local  ──►  UI
WebSocket        ──►  SQLite local  ──►  UI
OutboxWorker     ──►  SQLite local  ──►  UI
```

### UDF — Flujo estrictamente unidireccional

```
Usuario interactúa
        ↓
UI despacha Event           add(SendMessageEvent)
        ↓
BLoC procesa Event          _onSendMessage()
        ↓
Repository escribe          saveMessageWithOutbox()
        ↓
SQLite cambia               Drift emite en Stream
        ↓
BLoC emite nuevo State      emit.forEach → ChatLoaded
        ↓
UI se reconstruye           BlocBuilder → MessageBubble con ⏱
```

El `OutboxWorker` y el `ChatBloc` no se conocen entre sí — ambos interactúan únicamente
a través de SQLite. El SSOT actúa como bus de comunicación desacoplado.

---

## 🗄️ Modelo de Datos

### SQLite local (Flutter / Drift)

| Tabla | Propósito |
|-------|-----------|
| `users` | Usuario actual + contactos cacheados |
| `threads` | Conversaciones con último mensaje desnormalizado |
| `messages` | Mensajes con estado offline (`pending/sent/failed/received`) |
| `outbox` | Cola durable de operaciones pendientes ⭐ |

### PostgreSQL remoto (Backend Go)

| Tabla | Propósito |
|-------|-----------|
| `users` | Registro de usuarios |
| `threads` | Conversaciones entre dos usuarios |
| `messages` | Mensajes persistidos |
| `idempotency_keys` | Prevención de duplicados en reintentos |

> Los IDs son **UUID generados en el cliente**. No es necesario esperar al servidor
> para conocer el ID de lo que se creó — fundamental para offline-first.

---

## 🚀 Cómo Levantar el Proyecto

### Backend Go

```bash
cd chat_sync_backend
cp .env.example .env
# Editar .env: DATABASE_URL=postgres://user:pass@localhost:5432/chat_sync?sslmode=disable
psql -U postgres -c "CREATE DATABASE chat_sync;"
psql -U postgres -d chat_sync -f schema.sql
go mod tidy
go run cmd/main.go         # servidor en :8080
```

### Flutter App

```bash
cd chat_sync
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # genera código Drift
flutter run
```

> Ver los READMEs específicos de cada proyecto para instrucciones detalladas.

---

## 🧪 Escenarios Offline Probados

| Escenario | Comportamiento |
|-----------|---------------|
| WiFi desactivado → enviar mensajes | Mensajes en outbox con `⏱`, al reconectar → `✓` |
| Kill del servidor → enviar mensajes | Outbox acumula, al reiniciar servidor → sync automático |
| Tiempo real emulador → celular | WebSocket entrega el mensaje instantáneamente |
| App cerrada → mensajes recibidos | Delta sync al abrir trae los mensajes perdidos |

---

## 📦 Stack

| Capa | Tecnología |
|------|-----------|
| Cliente móvil | Flutter + Dart |
| Estado | BLoC (`flutter_bloc`) |
| DB local | Drift (SQLite ORM) |
| HTTP | Dio + interceptores (retry, auth) |
| Conectividad | `connectivity_plus` + ping real |
| Backend | Go + Gin |
| DB remota | PostgreSQL |
| Tiempo real | WebSocket (`gorilla/websocket`) |

---

## 🔀 Flujo de Trabajo con Git

Todos los comandos Git se ejecutan desde la **raíz del monorepo** (`chat_sync/`),
pero puedes abrir solo la carpeta que necesitas en el IDE cada día.

### Clone

```bash
git clone https://github.com/raulurtecho/chat_sync.git
cd chat_sync
```

### Flujo diario

```bash
# 1. Siempre jalar los últimos cambios primero
git pull origin main

# 2. Abrir solo la carpeta que trabajarás hoy
code chat_sync_backend/   # backend
code chat_sync/           # Flutter

# 3. Hacer cambios...

# 4. Agregar solo los archivos de la carpeta trabajada
git add chat_sync_backend/   # o git add chat_sync/

# 5. Commitear con mensaje descriptivo
git commit -m "feat(backend): add participant_name to threads"

# 6. Push
git push origin main
```

### Flujo con branches y PRs (recomendado)

```bash
# Crear branch para una feature
git checkout -b feat/offline-retry-button

# ... trabajar en chat_sync/ ...

git add chat_sync/
git commit -m "feat(app): add retry button on failed messages"
git push origin feat/offline-retry-button

# En GitHub → abrir PR hacia main → Merge → Delete branch

# De vuelta local — sincronizar y limpiar
git checkout main
git pull origin main
git branch -d feat/offline-retry-button
```

### Convención de commits

```bash
# Backend
git commit -m "feat(backend): descripción"
git commit -m "fix(backend): descripción"

# Flutter
git commit -m "feat(app): descripción"
git commit -m "fix(app): descripción"

# Raíz / ambos
git commit -m "docs: descripción"
git commit -m "chore: descripción"
```

| Prefijo | Cuándo usarlo |
|---------|--------------|
| `feat` | Nueva funcionalidad |
| `fix` | Corrección de bug |
| `docs` | Solo documentación |
| `chore` | Mantenimiento, dependencias |
| `refactor` | Refactoring sin cambio funcional |