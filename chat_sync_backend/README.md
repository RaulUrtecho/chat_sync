# ⚙️ ChatSync — Backend Go

Servidor HTTP + WebSocket para la app de chat offline-first.  
Stack: Go · Gin · PostgreSQL · gorilla/websocket

---

## 🏗️ Estructura

```
chat_sync_backend/
├── cmd/
│   └── main.go                  # Entry point — rutas y arranque
├── internal/
│   ├── db/
│   │   └── postgres.go          # Conexión + todas las queries
│   ├── handlers/
│   │   ├── users.go             # POST /users, GET /users/search
│   │   ├── threads.go           # POST /threads, GET /threads
│   │   └── messages.go          # POST /messages, GET /messages/:threadId
│   ├── models/
│   │   └── models.go            # Structs compartidos
│   └── ws/
│       └── hub.go               # WebSocket hub
├── schema.sql                   # DDL PostgreSQL
├── .env                         # Variables locales (no commitear)
└── .env.example                 # Template del .env (sí commitear)
```

---

## 🌐 Endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/health` | Ping del ConnectivityMonitor de Flutter |
| `GET` | `/ws?userId=` | Conexión WebSocket tiempo real |
| `POST` | `/users` | Registrar usuario |
| `GET` | `/users/search?q=` | Buscar usuarios por nombre |
| `POST` | `/threads` | Crear thread |
| `GET` | `/threads?userId=&since=` | Listar threads del usuario |
| `POST` | `/messages` | Enviar mensaje |
| `GET` | `/messages/:threadId?since=` | Obtener mensajes de un thread |

### Headers esperados

| Header | Descripción |
|--------|-------------|
| `X-User-Id` | UUID del usuario actual — inyectado por `AuthInterceptor` de Flutter |
| `X-Idempotency-Key` | UUID del recurso — previene duplicados en reintentos del outbox |
| `Content-Type` | `application/json` |

### Delta Sync

Los endpoints de listado soportan el parámetro `since` (RFC3339):

```
GET /threads?userId=uuid&since=2024-01-15T10:30:00Z
GET /messages/uuid?since=2024-01-15T10:30:00Z
```

Sin `since` → retorna todos los registros.  
Con `since` → retorna solo los creados después del cursor.

---

## 🗄️ Base de Datos

### Tablas

| Tabla | Descripción |
|-------|-------------|
| `users` | Usuarios registrados |
| `threads` | Conversaciones entre dos usuarios |
| `messages` | Mensajes con `created_at` del cliente |
| `idempotency_keys` | Cache de respuestas para reintentos del outbox |

### Decisiones de diseño

**IDs UUID del cliente** — el servidor acepta el UUID generado por Flutter, no genera IDs propios.
Permite crear registros locales con ID final sin esperar al servidor.

**`created_at` del cliente en mensajes** — preserva el timestamp real del momento en que el
usuario escribió el mensaje offline. Sin esto, todos los mensajes de una sesión offline tendrían
el mismo timestamp al sincronizarse.

**`ON CONFLICT DO NOTHING`** en todos los inserts — segunda línea de defensa además de las
idempotency keys. Si el mismo UUID llega dos veces, PostgreSQL ignora el segundo insert.

**`idempotency_keys` con TTL de 24h** — se limpian con `cleanup_idempotency_keys()`.

---

## ⚙️ Levantar el Proyecto

```bash
# 1. Variables de entorno
cp .env.example .env
# Editar .env:
# DATABASE_URL=postgres://postgres:tu_password@localhost:5432/chat_sync?sslmode=disable

# 2. Crear la base de datos
psql -U postgres -c "CREATE DATABASE chat_sync;"
psql -U postgres -d chat_sync -f schema.sql

# 3. Instalar dependencias
go mod tidy

# 4. Correr el servidor
go run cmd/main.go
```

El servidor estará disponible en:
```
HTTP:      http://localhost:8080
WebSocket: ws://localhost:8080/ws?userId=UUID
Health:    http://localhost:8080/health
```

### Hot reload con Air

```bash
go install github.com/air-verse/air@latest
air
```

---

## 🛠️ Comandos Útiles de Desarrollo

### Reset de base de datos

**Limpiar solo datos (más común en desarrollo):**
```sql
psql -U postgres -d chat_sync -c "TRUNCATE TABLE messages, threads, users, idempotency_keys CASCADE;"
```
El servidor Go **no necesita reiniciarse**.

**Recrear tablas (cuando cambias schema.sql):**
```bash
psql -U postgres -d chat_sync -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
psql -U postgres -d chat_sync -f schema.sql
```

**Recrear base de datos completa:**
```bash
# Detener el servidor primero (Ctrl+C)
psql -U postgres -c "DROP DATABASE chat_sync;"
psql -U postgres -c "CREATE DATABASE chat_sync;"
psql -U postgres -d chat_sync -f schema.sql
```

---

### Inspeccionar el estado

```sql
psql -U postgres -d chat_sync

-- Conteo por tabla
SELECT 'users' AS tabla, COUNT(*) FROM users
UNION ALL SELECT 'threads', COUNT(*) FROM threads
UNION ALL SELECT 'messages', COUNT(*) FROM messages
UNION ALL SELECT 'idempotency_keys', COUNT(*) FROM idempotency_keys;

-- Últimos mensajes
SELECT * FROM messages ORDER BY created_at DESC LIMIT 10;

-- Threads con participantes
SELECT t.id, u_a.name AS user_a, u_b.name AS user_b
FROM threads t
JOIN users u_a ON u_a.id = t.user_a_id
JOIN users u_b ON u_b.id = t.user_b_id;

\q
```

> El outbox (`pending`, `retries`) vive en **SQLite del dispositivo**, no en PostgreSQL.

---

### Verificar endpoints

```bash
# Health check
curl http://localhost:8080/health

# Crear usuario
curl -X POST http://localhost:8080/users \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: 00000000-0000-0000-0000-000000000001" \
  -d '{"id":"00000000-0000-0000-0000-000000000001","name":"Test"}'

# Buscar usuarios
curl "http://localhost:8080/users/search?q=test" \
  -H "X-User-Id: 00000000-0000-0000-0000-000000000001"

# Listar threads
curl "http://localhost:8080/threads?userId=00000000-0000-0000-0000-000000000001" \
  -H "X-User-Id: 00000000-0000-0000-0000-000000000001"
```

---

## 🔌 WebSocket

Flutter se conecta en: `ws://host:8080/ws?userId={uuid}`

### Eventos que el servidor envía al cliente

```json
// Mensaje nuevo
{
  "type": "new_message",
  "data": {
    "id": "uuid",
    "thread_id": "uuid",
    "sender_id": "uuid",
    "content": "Hola!",
    "created_at": "2024-01-15T10:30:00Z"
  }
}

// Thread sincronizado
{
  "type": "thread_synced",
  "data": { "id": "uuid" }
}
```

### Reconexión automática

El cliente Flutter (`SyncEngine`) reconecta automáticamente cuando el WebSocket se cierra.
Antes de reconectar siempre hace un **delta sync** para recuperar mensajes perdidos.

---

## 📦 Dependencias

| Paquete | Uso |
|---------|-----|
| `gin-gonic/gin` | Router HTTP |
| `lib/pq` | Driver PostgreSQL |
| `gorilla/websocket` | WebSocket |
| `google/uuid` | UUID v4 |
| `joho/godotenv` | Variables de entorno desde `.env` |