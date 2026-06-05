// internal/handlers/threads.go
//
// Handler de threads (conversaciones).
//
// ENDPOINTS:
//   POST /threads              → crear un nuevo thread
//   GET  /threads?userId=&since= → listar threads de un usuario
//
// IDEMPOTENCIA EN POST /threads:
//   El outbox del cliente puede intentar crear el mismo thread
//   múltiples veces si hay reintentos. El X-Idempotency-Key
//   junto con ON CONFLICT DO NOTHING en la DB garantizan
//   que solo se crea una vez.

package handlers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/db"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
)

// ThreadsHandler agrupa los handlers relacionados con threads.
type ThreadsHandler struct {
	db *db.DB
}

// NewThreadsHandler crea una nueva instancia del handler.
func NewThreadsHandler(db *db.DB) *ThreadsHandler {
	return &ThreadsHandler{db: db}
}

// CreateThread maneja POST /threads
//
// Crea un nuevo thread entre dos usuarios.
// Si el thread ya existe (mismo par de usuarios), retorna éxito
// sin error — el cliente puede haber reintentado la operación.
//
// REQUEST:
//
//	POST /threads
//	X-Idempotency-Key: {uuid-del-thread}
//	{
//	  "id": "uuid",
//	  "user_a_id": "uuid",
//	  "user_b_id": "uuid"
//	}
//
// RESPONSES:
//
//	201 Created     → thread creado exitosamente
//	200 OK          → reintento detectado, respuesta cacheada
//	400 Bad Request → body inválido
//	500 Internal    → error de base de datos
func (h *ThreadsHandler) CreateThread(c *gin.Context) {
	idempotencyKey := c.GetHeader("X-Idempotency-Key")

	// Verificar si ya fue procesado (reintento del outbox)
	if idempotencyKey != "" {
		cached, exists, err := h.db.CheckIdempotencyKey(c.Request.Context(), idempotencyKey)
		if err != nil {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
			return
		}
		if exists {
			c.Data(http.StatusOK, "application/json", cached)
			return
		}
	}

	var req models.CreateThreadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: err.Error()})
		return
	}

	thread, err := h.db.CreateThread(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	// Guardar para futuros reintentos
	if idempotencyKey != "" {
		_ = h.db.SaveIdempotencyKey(c.Request.Context(), idempotencyKey, thread)
	}

	c.JSON(http.StatusCreated, thread)
}

// GetThreads maneja GET /threads?userId={uuid}&since={timestamp}
//
// Retorna todos los threads de un usuario. Soporta delta sync
// mediante el parámetro opcional [since].
//
// REQUEST:
//
//	GET /threads?userId=uuid
//	GET /threads?userId=uuid&since=2024-01-15T10:30:00Z  ← delta sync
//	X-User-Id: {uuid-del-usuario-actual}
//
// RESPONSES:
//
//	200 OK          → lista de threads (puede ser [])
//	400 Bad Request → userId faltante o inválido
//	500 Internal    → error de base de datos
func (h *ThreadsHandler) GetThreads(c *gin.Context) {
	// Obtener y validar el userId del query param
	userIDStr := c.Query("userId")
	if userIDStr == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "el parámetro 'userId' es requerido",
		})
		return
	}

	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "userId inválido",
		})
		return
	}

	// Parsear el cursor de delta sync (opcional)
	// Formato esperado: RFC3339 → "2024-01-15T10:30:00Z"
	var since *time.Time
	if sinceStr := c.Query("since"); sinceStr != "" {
		parsed, err := time.Parse(time.RFC3339, sinceStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error: "formato de 'since' inválido, usar RFC3339: 2006-01-02T15:04:05Z",
			})
			return
		}
		since = &parsed
	}

	threads, err := h.db.GetThreadsByUser(c.Request.Context(), userID, since)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	c.JSON(http.StatusOK, threads)
}
