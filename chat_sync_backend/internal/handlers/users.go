// internal/handlers/users.go
//
// Handler de usuarios.
//
// ENDPOINTS:
//   POST /users           → registrar un nuevo usuario
//   GET  /users/search    → buscar usuarios por nombre
//
// IDEMPOTENCIA EN POST /users:
//   El cliente Flutter envía X-Idempotency-Key: {uuid-del-usuario}.
//   Si el servidor ya procesó este key (reintento del outbox),
//   retorna la respuesta cacheada sin reprocesar.

package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/db"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
)

// UsersHandler agrupa los handlers relacionados con usuarios.
type UsersHandler struct {
	db *db.DB
}

// NewUsersHandler crea una nueva instancia del handler.
func NewUsersHandler(db *db.DB) *UsersHandler {
	return &UsersHandler{db: db}
}

// CreateUser maneja POST /users
//
// Registra un nuevo usuario en el sistema.
// El ID viene del cliente — no se genera uno nuevo en el servidor.
//
// REQUEST:
//
//	POST /users
//	X-Idempotency-Key: {uuid-del-usuario}
//	{ "id": "uuid", "name": "Juan" }
//
// RESPONSES:
//
//	201 Created  → usuario creado exitosamente
//	200 OK       → reintento detectado, retorna respuesta cacheada
//	400 Bad Request → body inválido
//	500 Internal → error de base de datos
func (h *UsersHandler) CreateUser(c *gin.Context) {
	// Leer el idempotency key del header
	idempotencyKey := c.GetHeader("X-Idempotency-Key")

	// Si hay idempotency key, verificar si ya fue procesado
	if idempotencyKey != "" {
		cached, exists, err := h.db.CheckIdempotencyKey(c.Request.Context(), idempotencyKey)
		if err != nil {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
			return
		}
		if exists {
			// Reintento detectado — retornar respuesta cacheada
			c.Data(http.StatusOK, "application/json", cached)
			return
		}
	}

	// Parsear y validar el body
	var req models.CreateUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: err.Error()})
		return
	}

	// Crear el usuario en la base de datos
	user, err := h.db.CreateUser(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	// Guardar el key y la respuesta para futuros reintentos
	if idempotencyKey != "" {
		_ = h.db.SaveIdempotencyKey(c.Request.Context(), idempotencyKey, user)
	}

	c.JSON(http.StatusCreated, user)
}

// SearchUsers maneja GET /users/search?q={query}
//
// Busca usuarios por nombre. Se usa en el search bar de ThreadsScreen.
// Excluye al usuario que hace la búsqueda (header X-User-Id).
//
// REQUEST:
//
//	GET /users/search?q=juan
//	X-User-Id: {uuid-del-usuario-actual}
//
// RESPONSES:
//
//	200 OK       → lista de usuarios (puede ser vacía [])
//	400 Bad Request → query vacía o userId inválido
//	500 Internal → error de base de datos
func (h *UsersHandler) SearchUsers(c *gin.Context) {
	query := c.Query("q")
	if query == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "el parámetro 'q' es requerido",
		})
		return
	}

	// Obtener el userId del header para excluirlo de los resultados
	// Si no viene el header, usar UUID nil (no excluir a nadie)
	currentUserID := uuid.Nil
	if userIDStr := c.GetHeader("X-User-Id"); userIDStr != "" {
		parsed, err := uuid.Parse(userIDStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error: "X-User-Id inválido",
			})
			return
		}
		currentUserID = parsed
	}

	users, err := h.db.SearchUsers(c.Request.Context(), query, currentUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	c.JSON(http.StatusOK, users)
}
