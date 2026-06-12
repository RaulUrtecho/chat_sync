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
//   5. Notificar por WebSocket + Push Notification a los participantes
//   6. Retornar 201
//
// DOS CANALES DE NOTIFICACIÓN (paso 5):
//
//   WebSocket  → tiempo real, solo si la app está abierta y conectada
//   FCM Push   → funciona aunque la app esté cerrada o en background

package handlers

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/db"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/ws"
	"google.golang.org/api/option"
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
// participantes del thread vía WebSocket + Push Notification.
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
			// Reintento detectado — retornar respuesta cacheada sin reprocesar.
			// IMPORTANTE: no volver a notificar por WebSocket ni FCM para
			// evitar que el destinatario reciba la misma notificación dos veces.
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

	// Notificar por WebSocket + FCM en una goroutine separada.
	// Así la respuesta HTTP al sender no espera las notificaciones —
	// si fallan no afecta la persistencia del mensaje.
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
	threadIDStr := c.Param("threadId")
	threadID, err := uuid.Parse(threadIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "threadId inválido",
		})
		return
	}

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

// notifyParticipants envía el mensaje nuevo por WebSocket Y push notification.
//
// Se llama en una goroutine desde CreateMessage — context.Background()
// porque la goroutine sobrevive al request HTTP original (cuyo context
// puede estar ya cancelado cuando esta función se ejecuta).
//
// FLUJO:
//  1. Obtener IDs de ambos participantes del thread
//  2. Notificar por WebSocket a ambos (tiempo real si app está abierta)
//  3. Determinar quién es el destinatario (el que NO es el sender)
//  4. Enviar push notification FCM al destinatario
//     → funciona aunque la app esté cerrada o en background
func (h *MessagesHandler) notifyParticipants(msg models.Message) {
	ctx := context.Background()

	userAID, userBID, err := h.db.GetThreadParticipants(ctx, msg.ThreadID)
	if err != nil {
		// No crítico — el delta sync compensará al reconectar
		return
	}

	// 1. WebSocket: notificar a ambos participantes
	event := models.WSEvent{
		Type: models.WSEventNewMessage,
		Data: msg,
	}
	h.hub.SendToUser(userAID, event)
	h.hub.SendToUser(userBID, event)

	// 2. FCM Push: solo al destinatario, no al sender.
	// El sender ya ve el mensaje en su UI (Optimistic UI).
	// Enviarle push al sender causaría una notificación duplicada innecesaria.
	recipientID := userBID
	if msg.SenderID == userBID {
		recipientID = userAID
	}

	h.sendPushNotification(ctx, recipientID, msg)
}

// sendPushNotification envía una push notification via Firebase Admin SDK.
//
// Usa el Firebase Admin SDK oficial (firebase-admin-go) en lugar de
// llamadas HTTP manuales — más simple, tipado y con manejo automático
// de tokens OAuth2.
//
// VARIABLES DE ENTORNO REQUERIDAS:
//
//	FIREBASE_SERVICE_ACCOUNT_JSON → contenido del JSON de la service account
//	                                 descargado de Firebase Console →
//	                                 Project Settings → Service Accounts
//
// MANEJO DE TOKEN INVÁLIDO:
//
//	FCM retorna un error específico cuando el token del dispositivo es inválido:
//	· Usuario desinstalό la app
//	· Token rotado por FCM y Flutter aún no envió el nuevo
//
//	En ese caso limpiamos el token en la DB. La próxima vez que el usuario
//	abra la app, Flutter enviará el nuevo token via PUT /users/:id/fcm-token.
func (h *MessagesHandler) sendPushNotification(ctx context.Context, recipientID uuid.UUID, msg models.Message) {
	// 1. Obtener FCM token del destinatario
	token, err := h.db.GetFCMToken(ctx, recipientID)
	if err != nil || token == nil {
		// Sin token: usuario nunca abrió la app con FCM registrado,
		// o desinstalό la app y el token ya fue limpiado.
		log.Printf("[FCM] Sin token para usuario %s — omitiendo push", recipientID)
		return
	}

	// 2. Inicializar Firebase Admin SDK con las credenciales de la service account
	serviceAccountJSON := os.Getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
	if serviceAccountJSON == "" {
		log.Printf("[FCM] FIREBASE_SERVICE_ACCOUNT_JSON no configurado")
		return
	}

	app, err := firebase.NewApp(ctx, nil,
		option.WithAuthCredentialsJSON(option.ServiceAccount, []byte(serviceAccountJSON)),
	)
	if err != nil {
		log.Printf("[FCM] Error inicializando Firebase App: %v", err)
		return
	}

	// 3. Obtener el cliente de mensajería FCM
	client, err := app.Messaging(ctx)
	if err != nil {
		log.Printf("[FCM] Error obteniendo cliente FCM: %v", err)
		return
	}

	// 4. Construir y enviar el mensaje FCM
	//
	// notification → se muestra en la bandeja del sistema (título + cuerpo)
	// data         → datos extra para Flutter al tocar la notificación
	//                Flutter puede usarlos para navegar al thread correcto
	// android      → configuración específica de Android:
	//                channel_id debe coincidir con el canal creado en Flutter
	//                ("chat_messages" en NotificationService)
	_, err = client.Send(ctx, &messaging.Message{
		Token: *token,
		Notification: &messaging.Notification{
			Title: "Nuevo mensaje",
			Body:  msg.Content,
		},
		Data: map[string]string{
			"thread_id":  msg.ThreadID.String(),
			"sender_id":  msg.SenderID.String(),
			"message_id": msg.ID.String(),
		},
		Android: &messaging.AndroidConfig{
			Notification: &messaging.AndroidNotification{
				ChannelID: "chat_messages", // debe coincidir con Flutter NotificationService
				Priority:  messaging.PriorityHigh,
			},
		},
	})

	if err != nil {
		log.Printf("[FCM] Error enviando push a usuario %s: %v", recipientID, err)

		// Si el token es inválido, limpiarlo en la DB.
		// messaging.IsRegistrationTokenNotRegistered detecta exactamente este caso.
		if messaging.IsUnregistered(err) {
			log.Printf("[FCM] Token inválido para usuario %s — limpiando token", recipientID)
			h.db.UpdateFCMToken(ctx, recipientID, "")
		}
		return
	}

	log.Printf("[FCM] Push enviado exitosamente a usuario %s", recipientID)
}
