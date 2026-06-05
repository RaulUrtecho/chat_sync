-- schema.sql
--
-- Schema PostgreSQL para ChatSync backend.
--
-- EJECUTAR:
--   psql -U postgres -d chat_sync -f schema.sql
--
-- NOTAS DE DISEÑO:
--   · IDs son UUID generados en el CLIENTE (no serial/autoincrement).
--     Fundamental para offline-first: el cliente crea registros con
--     su ID final sin esperar respuesta del servidor.
--
--   · La tabla idempotency_keys previene duplicados cuando el cliente
--     reintenta una operación después de un timeout. El servidor
--     verifica esta tabla antes de procesar cualquier escritura.
--
--   · Los índices están orientados a las queries más frecuentes:
--     búsqueda de usuarios por nombre, mensajes por thread ordenados
--     por fecha, threads por usuario.

-- =============================================================================
-- EXTENSIONES
-- =============================================================================

-- uuid-ossp: funciones UUID en PostgreSQL (útil para testing/seeds)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- pg_trgm: índices trigram para búsqueda ILIKE eficiente en nombres
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- =============================================================================
-- USUARIOS
-- =============================================================================

CREATE TABLE IF NOT EXISTS users (
    id          UUID        PRIMARY KEY,
    name        VARCHAR(50) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice trigram para búsqueda por nombre con ILIKE '%query%'
-- Sin este índice, la búsqueda haría un full table scan en cada keystroke
CREATE INDEX IF NOT EXISTS idx_users_name_trgm
    ON users USING gin(name gin_trgm_ops);

-- =============================================================================
-- THREADS
-- =============================================================================
--
-- Un thread es la conversación entre exactamente dos usuarios.
-- No hay orden fijo entre user_a y user_b — el cliente siempre
-- los ordena alfabéticamente al generar el UUID v5 determinístico,
-- lo que garantiza que el mismo par de usuarios siempre obtenga
-- el mismo thread_id.

CREATE TABLE IF NOT EXISTS threads (
    id          UUID        PRIMARY KEY,
    user_a_id   UUID        NOT NULL REFERENCES users(id),
    user_b_id   UUID        NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Un par de usuarios solo puede tener un thread.
    -- El cliente lo garantiza con UUID v5, el servidor lo refuerza
    -- como segunda línea de defensa contra race conditions.
    CONSTRAINT unique_thread_per_pair UNIQUE (user_a_id, user_b_id)
);

-- Índice para buscar threads de un usuario (cualquiera de los dos roles)
CREATE INDEX IF NOT EXISTS idx_threads_user_a ON threads(user_a_id);
CREATE INDEX IF NOT EXISTS idx_threads_user_b ON threads(user_b_id);

-- =============================================================================
-- MENSAJES
-- =============================================================================

CREATE TABLE IF NOT EXISTS messages (
    id          UUID        PRIMARY KEY,
    thread_id   UUID        NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    sender_id   UUID        NOT NULL REFERENCES users(id),
    content     TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice principal: mensajes de un thread ordenados cronológicamente.
-- Es la query más frecuente: GET /messages/:threadId?since=...
CREATE INDEX IF NOT EXISTS idx_messages_thread_created
    ON messages(thread_id, created_at ASC);

-- =============================================================================
-- IDEMPOTENCY KEYS
-- =============================================================================
--
-- Previene duplicados cuando el cliente reintenta una operación.
-- PROBLEMA: el cliente envía POST /messages, el servidor lo procesa
-- y guarda el mensaje, pero el ACK se pierde en la red (timeout).
-- El cliente reintenta → sin este mecanismo, el mensaje se duplicaría.
--
-- SOLUCIÓN: el cliente envía X-Idempotency-Key: {uuid-del-mensaje}.
-- El servidor verifica esta tabla antes de procesar:
--   · Si el key NO existe → procesar y guardar el key
--   · Si el key YA existe → retornar 200 sin reprocesar
--
-- TTL: las keys se limpian después de 24h (suficiente para cualquier retry).

CREATE TABLE IF NOT EXISTS idempotency_keys (
    key         TEXT        PRIMARY KEY,
    -- Guardar la respuesta original para retornarla idéntica en reintentos
    response    JSONB       NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice para limpieza automática por TTL
CREATE INDEX IF NOT EXISTS idx_idempotency_created
    ON idempotency_keys(created_at);

-- =============================================================================
-- FUNCIÓN DE LIMPIEZA DE IDEMPOTENCY KEYS
-- =============================================================================
--
-- Elimina keys más antiguas de 24h.
-- Llamar periódicamente (ej: cron job diario o desde el backend al iniciar).

CREATE OR REPLACE FUNCTION cleanup_idempotency_keys()
RETURNS void AS $$
BEGIN
    DELETE FROM idempotency_keys
    WHERE created_at < NOW() - INTERVAL '24 hours';
END;
$$ LANGUAGE plpgsql;