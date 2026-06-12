// internal/db/postgres.go
//
// Conexión a PostgreSQL y todas las queries de la aplicación.
//
// RESPONSABILIDAD:
//   · Abrir y verificar la conexión a PostgreSQL
//   · Encapsular todas las queries SQL en métodos tipados
//   · Manejar idempotency keys para prevenir duplicados
//
// PATRÓN:
//   Se usa database/sql estándar de Go con el driver lib/pq.
//   Todas las queries usan placeholders $1, $2... (estilo PostgreSQL)
//   para prevenir SQL injection.
//
// USO:
//   db, err := db.Connect(os.Getenv("DATABASE_URL"))
//   user, err := db.CreateUser(ctx, req)

package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq" // driver PostgreSQL — importado por side effects
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
)

// DB es el wrapper sobre *sql.DB que expone los métodos de acceso a datos.
//
// Se registra como singleton en main.go y se pasa a los handlers
// por inyección de dependencias.
type DB struct {
	conn *sql.DB
}

// Connect abre la conexión a PostgreSQL y verifica que esté activa.
//
// [dataSourceName] es la DATABASE_URL del .env:
//
//	postgres://user:pass@localhost:5432/chat_sync?sslmode=disable
func Connect(dataSourceName string) (*DB, error) {
	conn, err := sql.Open("postgres", dataSourceName)
	if err != nil {
		return nil, fmt.Errorf("error abriendo conexión: %w", err)
	}

	// Verificar que la conexión esté activa con un ping real
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := conn.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("error conectando a PostgreSQL: %w", err)
	}

	// Pool de conexiones — configuración para una app de chat con
	// múltiples clientes conectados simultáneamente
	conn.SetMaxOpenConns(25)
	conn.SetMaxIdleConns(10)
	conn.SetConnMaxLifetime(5 * time.Minute)

	return &DB{conn: conn}, nil
}

// Close cierra el pool de conexiones.
func (db *DB) Close() error {
	return db.conn.Close()
}

// =============================================================================
// IDEMPOTENCY KEYS
// =============================================================================

// CheckIdempotencyKey verifica si una operación ya fue procesada.
//
// Retorna (response, true, nil) si el key ya existe — el handler
// debe retornar la respuesta cacheada sin reprocesar.
// Retorna (nil, false, nil) si el key no existe — proceder normalmente.
func (db *DB) CheckIdempotencyKey(ctx context.Context, key string) (json.RawMessage, bool, error) {
	var response json.RawMessage
	err := db.conn.QueryRowContext(ctx,
		`SELECT response FROM idempotency_keys WHERE key = $1`,
		key,
	).Scan(&response)

	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("error verificando idempotency key: %w", err)
	}

	return response, true, nil
}

// SaveIdempotencyKey guarda el key y la respuesta para futuros reintentos.
//
// Se llama DESPUÉS de procesar la operación exitosamente.
// La respuesta se serializa a JSON para almacenarse en la columna JSONB.
func (db *DB) SaveIdempotencyKey(ctx context.Context, key string, response any) error {
	responseJSON, err := json.Marshal(response)
	if err != nil {
		return fmt.Errorf("error serializando respuesta: %w", err)
	}

	_, err = db.conn.ExecContext(ctx,
		`INSERT INTO idempotency_keys (key, response, created_at)
		 VALUES ($1, $2, NOW())
		 ON CONFLICT (key) DO NOTHING`,
		key, responseJSON,
	)
	return err
}

// =============================================================================
// USUARIOS
// =============================================================================

// CreateUser inserta un nuevo usuario en la base de datos.
//
// Usa INSERT ... ON CONFLICT DO NOTHING para que un reintento
// del cliente (sin idempotency key) no falle con un error de
// duplicado — simplemente no inserta si el UUID ya existe.
func (db *DB) CreateUser(ctx context.Context, req models.CreateUserRequest) (models.User, error) {
	user := models.User{
		ID:        req.ID,
		Name:      req.Name,
		CreatedAt: time.Now().UTC(),
	}

	_, err := db.conn.ExecContext(ctx,
		`INSERT INTO users (id, name, created_at)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (id) DO NOTHING`,
		user.ID, user.Name, user.CreatedAt,
	)
	if err != nil {
		return models.User{}, fmt.Errorf("error creando usuario: %w", err)
	}

	return user, nil
}

// UpdateFCMToken guarda o actualiza el FCM token de un usuario.
//
// Se llama en cada arranque de la app Flutter para mantener el token
// vigente. FCM puede rotar el token sin aviso, por lo que enviarlo
// en cada arranque garantiza que siempre tengamos el token correcto.
//
// Si token es "" significa que el token anterior era inválido
// (FCM retornó "registration-token-not-registered") y se está limpiando.
func (db *DB) UpdateFCMToken(ctx context.Context, userID uuid.UUID, token string) error {
	var tokenValue interface{}
	if token == "" {
		tokenValue = nil // guardar NULL en lugar de string vacío
	} else {
		tokenValue = token
	}

	_, err := db.conn.ExecContext(ctx,
		`UPDATE users SET fcm_token = $1 WHERE id = $2`,
		tokenValue, userID,
	)
	if err != nil {
		return fmt.Errorf("error actualizando FCM token: %w", err)
	}
	return nil
}

// GetFCMToken obtiene el FCM token de un usuario.
//
// Retorna nil si:
//   - El usuario no existe
//   - El usuario nunca registró un token (primera instalación)
//   - El token fue limpiado porque era inválido (desinstalación)
//
// El caller debe verificar nil antes de intentar enviar una notificación.
func (db *DB) GetFCMToken(ctx context.Context, userID uuid.UUID) (*string, error) {
	var token *string
	err := db.conn.QueryRowContext(ctx,
		`SELECT fcm_token FROM users WHERE id = $1`,
		userID,
	).Scan(&token)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("error obteniendo FCM token: %w", err)
	}
	return token, nil
}

// SearchUsers busca usuarios cuyo nombre contenga [query].
//
// Usa ILIKE para búsqueda case-insensitive con el índice trigram
// definido en schema.sql (idx_users_name_trgm).
// Excluye al usuario que hace la búsqueda ([excludeUserID]).
// Límite de 20 resultados para no sobrecargar la respuesta.
func (db *DB) SearchUsers(ctx context.Context, query string, excludeUserID uuid.UUID) ([]models.User, error) {
	rows, err := db.conn.QueryContext(ctx,
		`SELECT id, name, created_at
		 FROM users
		 WHERE name ILIKE $1
		   AND id != $2
		 ORDER BY name ASC
		 LIMIT 20`,
		"%"+query+"%", excludeUserID,
	)
	if err != nil {
		return nil, fmt.Errorf("error buscando usuarios: %w", err)
	}
	defer rows.Close()

	return scanUsers(rows)
}

// =============================================================================
// THREADS
// =============================================================================

// CreateThread inserta un nuevo thread entre dos usuarios.
//
// ON CONFLICT DO NOTHING: si el thread ya existe (mismo par de usuarios),
// no falla — es el comportamiento correcto para el outbox pattern donde
// el mismo thread puede intentar crearse múltiples veces por reintentos.
func (db *DB) CreateThread(ctx context.Context, req models.CreateThreadRequest) (models.Thread, error) {
	thread := models.Thread{
		ID:            req.ID,
		UserAID:       req.UserAID,
		UserBID:       req.UserBID,
		ParticipantID: req.UserBID, // desde la perspectiva de UserA
		CreatedAt:     time.Now().UTC(),
	}

	_, err := db.conn.ExecContext(ctx,
		`INSERT INTO threads (id, user_a_id, user_b_id, created_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT DO NOTHING`,
		thread.ID, thread.UserAID, thread.UserBID, thread.CreatedAt,
	)
	if err != nil {
		return models.Thread{}, fmt.Errorf("error creando thread: %w", err)
	}

	return thread, nil
}

// GetThreadsByUser retorna todos los threads de un usuario con delta sync.
//
// [userID] el usuario cuyos threads se quieren obtener.
// [since] si no es zero, solo retorna threads creados/actualizados después.
//
// La query calcula:
//   - participant_id: el otro usuario del thread (no el que consulta)
//   - last_message: último mensaje del thread (subquery)
//   - last_message_at: timestamp del último mensaje (subquery)
func (db *DB) GetThreadsByUser(ctx context.Context, userID uuid.UUID, since *time.Time) ([]models.Thread, error) {
	query := `
		SELECT
			t.id,
			t.user_a_id,
			t.user_b_id,
			t.created_at,
			CASE WHEN t.user_a_id = $1 THEN t.user_b_id
			     ELSE t.user_a_id
			END AS participant_id,
			(SELECT u.name FROM users u
			 WHERE u.id = CASE WHEN t.user_a_id = $1 THEN t.user_b_id
			                   ELSE t.user_a_id END) AS participant_name,
			(SELECT content FROM messages m
			 WHERE m.thread_id = t.id
			 ORDER BY m.created_at DESC LIMIT 1) AS last_message,
			(SELECT created_at FROM messages m
			 WHERE m.thread_id = t.id
			 ORDER BY m.created_at DESC LIMIT 1) AS last_message_at
		FROM threads t
		WHERE (t.user_a_id = $1 OR t.user_b_id = $1)`

	args := []any{userID}

	if since != nil {
		query += ` AND t.created_at > $2`
		args = append(args, since)
	}

	query += ` ORDER BY last_message_at DESC NULLS LAST`

	rows, err := db.conn.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("error obteniendo threads: %w", err)
	}
	defer rows.Close()

	return scanThreads(rows)
}

// =============================================================================
// MENSAJES
// =============================================================================

// CreateMessage inserta un nuevo mensaje en un thread.
//
// CreatedAt viene del cliente para preservar el timestamp original
// del momento en que el usuario escribió el mensaje (offline-first).
func (db *DB) CreateMessage(ctx context.Context, req models.CreateMessageRequest) (models.Message, error) {
	msg := models.Message{
		ID:        req.ID,
		ThreadID:  req.ThreadID,
		SenderID:  req.SenderID,
		Content:   req.Content,
		CreatedAt: req.CreatedAt,
	}

	_, err := db.conn.ExecContext(ctx,
		`INSERT INTO messages (id, thread_id, sender_id, content, created_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (id) DO NOTHING`,
		msg.ID, msg.ThreadID, msg.SenderID, msg.Content, msg.CreatedAt,
	)
	if err != nil {
		return models.Message{}, fmt.Errorf("error creando mensaje: %w", err)
	}

	return msg, nil
}

// GetMessagesByThread retorna los mensajes de un thread con delta sync.
//
// [threadID] el thread cuyos mensajes se quieren obtener.
// [since] si no es zero, solo retorna mensajes creados después de este timestamp.
//
// Esta es la query que alimenta el delta sync del SyncEngine de Flutter:
//
//	GET /messages/{threadId}?since=2024-01-15T10:30:00Z
func (db *DB) GetMessagesByThread(ctx context.Context, threadID uuid.UUID, since *time.Time) ([]models.Message, error) {
	query := `
		SELECT id, thread_id, sender_id, content, created_at
		FROM messages
		WHERE thread_id = $1`

	args := []any{threadID}

	// Delta sync: solo mensajes después del cursor
	if since != nil {
		query += ` AND created_at > $2`
		args = append(args, since)
	}

	query += ` ORDER BY created_at ASC`

	rows, err := db.conn.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("error obteniendo mensajes: %w", err)
	}
	defer rows.Close()

	return scanMessages(rows)
}

// GetThreadParticipants retorna los IDs de ambos participantes de un thread.
//
// Se usa en el handler de mensajes para notificar por WebSocket a ambos
// usuarios cuando llega un mensaje nuevo.
func (db *DB) GetThreadParticipants(ctx context.Context, threadID uuid.UUID) (uuid.UUID, uuid.UUID, error) {
	var userAID, userBID uuid.UUID
	err := db.conn.QueryRowContext(ctx,
		`SELECT user_a_id, user_b_id FROM threads WHERE id = $1`,
		threadID,
	).Scan(&userAID, &userBID)

	if err == sql.ErrNoRows {
		return uuid.Nil, uuid.Nil, fmt.Errorf("thread no encontrado: %s", threadID)
	}
	if err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("error obteniendo participantes: %w", err)
	}

	return userAID, userBID, nil
}

// =============================================================================
// HELPERS — scan de rows
// =============================================================================

// scanUsers convierte sql.Rows a []models.User.
func scanUsers(rows *sql.Rows) ([]models.User, error) {
	var users []models.User
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.Name, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("error escaneando usuario: %w", err)
		}
		users = append(users, u)
	}
	// Retornar slice vacío en lugar de nil para que el JSON sea [] no null
	if users == nil {
		users = []models.User{}
	}
	return users, rows.Err()
}

// scanThreads convierte sql.Rows a []models.Thread.
func scanThreads(rows *sql.Rows) ([]models.Thread, error) {
	var threads []models.Thread
	for rows.Next() {
		var t models.Thread
		if err := rows.Scan(
			&t.ID,
			&t.UserAID,
			&t.UserBID,
			&t.CreatedAt,
			&t.ParticipantID,
			&t.ParticipantName,
			&t.LastMessage,
			&t.LastMessageAt,
		); err != nil {
			return nil, fmt.Errorf("error escaneando thread: %w", err)
		}
		threads = append(threads, t)
	}
	if threads == nil {
		threads = []models.Thread{}
	}
	return threads, rows.Err()
}

// scanMessages convierte sql.Rows a []models.Message.
func scanMessages(rows *sql.Rows) ([]models.Message, error) {
	var msgs []models.Message
	for rows.Next() {
		var m models.Message
		if err := rows.Scan(
			&m.ID,
			&m.ThreadID,
			&m.SenderID,
			&m.Content,
			&m.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("error escaneando mensaje: %w", err)
		}
		msgs = append(msgs, m)
	}
	if msgs == nil {
		msgs = []models.Message{}
	}
	return msgs, rows.Err()
}
