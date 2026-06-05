// internal/handlers/messages.go
//
// Handler de mensajes.
//
// ENDPOINTS:
//   POST /messages                          → enviar un mensaje
//   GET  /messages/:threadId?since=         → obtener mensajes de un thread
//
// FLUJO DE POST /messages (el más importante del proyecto):
//
//   1. Verificar idempotency key (reintento del outbox?)
//   2. Parsear y validar el body
//   3. Insertar mensaje en PostgreSQL
//   4. Guardar idempotency key
//   5. Notificar por WebSocket a los participantes del thread
//   6. Retornar 201
//
// El paso 5 es lo que hace que el chat sea en tiempo real:
// cuando el servidor recibe un mensaje, lo empuja inmediatamente
// a todos los clientes conectados al thread via WebSocket.

package handlers

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/db"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/ws"
)

// MessagesHandler agrupa los handlers relacionados con mensajes.
type MessagesHandler struct {
	db  *db.DB
	hub *ws.Hub
}

// NewMessagesHandler crea una nueva instancia del handler.
//
// Recibe el WebSocket Hub para poder notificar a los clientes
// conectados cuando llega un mensaje nuevo.
func NewMessagesHandler(db *db.DB, hub *ws.Hub) *MessagesHandler {
	return &MessagesHandler{db: db, hub: hub}
}

// CreateMessage maneja POST /messages
//
// Persiste un mensaje y lo notifica en tiempo real a los
// participantes del thread vía WebSocket.
//
// REQUEST:
//
//	POST /messages
//	X-Idempotency-Key: {uuid-del-mensaje}
//	{
//	  "id":         "uuid",
//	  "thread_id":  "uuid",
//	  "sender_id":  "uuid",
//	  "content":    "Hola!",
//	  "created_at": "2024-01-15T10:30:00Z"
//	}
//
// RESPONSES:
//
//	201 Created     → mensaje guardado y notificado
//	200 OK          → reintento detectado, respuesta cacheada
//	400 Bad Request → body inválido
//	500 Internal    → error de base de datos
func (h *MessagesHandler) CreateMessage(c *gin.Context) {
	idempotencyKey := c.GetHeader("X-Idempotency-Key")

	// Verificar reintento del outbox
	if idempotencyKey != "" {
		cached, exists, err := h.db.CheckIdempotencyKey(c.Request.Context(), idempotencyKey)
		if err != nil {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
			return
		}
		if exists {
			// Reintento — retornar respuesta cacheada sin reprocesar
			// IMPORTANTE: no volver a notificar por WebSocket
			c.Data(http.StatusOK, "application/json", cached)
			return
		}
	}

	var req models.CreateMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: err.Error()})
		return
	}

	// Persistir el mensaje en PostgreSQL
	msg, err := h.db.CreateMessage(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	// Guardar idempotency key para futuros reintentos
	if idempotencyKey != "" {
		_ = h.db.SaveIdempotencyKey(c.Request.Context(), idempotencyKey, msg)
	}

	// Notificar por WebSocket a los participantes del thread.
	//
	// Se hace de forma asíncrona (goroutine) para no bloquear
	// la respuesta HTTP al cliente que envió el mensaje.
	// Si la notificación WS falla, no afecta la persistencia —
	// el SyncEngine hará delta sync al reconectar de todas formas.
	go h.notifyParticipants(msg)

	c.JSON(http.StatusCreated, msg)
}

// GetMessages maneja GET /messages/:threadId?since={timestamp}
//
// Retorna los mensajes de un thread. Soporta delta sync
// mediante el parámetro opcional [since].
//
// REQUEST:
//
//	GET /messages/uuid
//	GET /messages/uuid?since=2024-01-15T10:30:00Z  ← delta sync
//	X-User-Id: {uuid-del-usuario-actual}
//
// RESPONSES:
//
//	200 OK          → lista de mensajes (puede ser [])
//	400 Bad Request → threadId inválido o since mal formateado
//	500 Internal    → error de base de datos
func (h *MessagesHandler) GetMessages(c *gin.Context) {
	// Parsear el threadId del path param
	threadIDStr := c.Param("threadId")
	threadID, err := uuid.Parse(threadIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "threadId inválido",
		})
		return
	}

	// Parsear el cursor de delta sync (opcional)
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

	msgs, err := h.db.GetMessagesByThread(c.Request.Context(), threadID, since)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: err.Error()})
		return
	}

	c.JSON(http.StatusOK, msgs)
}

// =============================================================================
// HELPERS PRIVADOS
// =============================================================================

// notifyParticipants envía el mensaje nuevo por WebSocket a ambos
// participantes del thread.
//
// Se llama en una goroutine desde CreateMessage para no bloquear
// la respuesta HTTP.
//
// FLUJO:
//  1. Obtener los IDs de ambos participantes del thread
//  2. Construir el evento WSEventNewMessage
//  3. Broadcast al sender (para confirmar en otros dispositivos)
//  4. Broadcast al receiver (para mostrar el mensaje en tiempo real)
func (h *MessagesHandler) notifyParticipants(msg models.Message) {
	// Usar context.Background() porque la goroutine sobrevive
	// al request HTTP original (cuyo context ya puede estar cancelado)
	userAID, userBID, err := h.db.GetThreadParticipants(context.Background(), msg.ThreadID)
	if err != nil {
		// Error no crítico — el delta sync compensará la falta de notificación
		return
	}

	event := models.WSEvent{
		Type: models.WSEventNewMessage,
		Data: msg,
	}

	// Notificar a ambos participantes
	h.hub.SendToUser(userAID, event)
	h.hub.SendToUser(userBID, event)
}
