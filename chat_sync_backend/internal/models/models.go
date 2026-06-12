// internal/models/models.go
//
// Structs compartidos entre handlers, db y ws.
//
// RESPONSABILIDAD:
//   Definir las estructuras de datos que viajan entre capas:
//   · DB → Handler (rows escaneados de PostgreSQL)
//   · Handler → Cliente (JSON responses)
//   · Cliente → Handler (JSON requests)
//   · Hub WS → Cliente (eventos WebSocket)
//
// CONVENCIONES:
//   · json tags en snake_case  → consistente con el cliente Flutter
//   · db tags                  → mapean columnas PostgreSQL al struct
//   · omitempty                → campos opcionales no se incluyen en el JSON
//     si son nil o zero value

package models

import (
	"time"

	"github.com/google/uuid"
)

// =============================================================================
// USUARIOS
// =============================================================================

// User representa un usuario del sistema.
type User struct {
	ID   uuid.UUID `json:"id"         db:"id"`
	Name string    `json:"name"       db:"name"`
	// FCMToken es el token de Firebase Cloud Messaging del dispositivo.
	//
	// CICLO DE VIDA DEL TOKEN:
	//   · Se genera cuando la app arranca por primera vez con FCM
	//   · Puede cambiar cuando: el usuario reinstala la app, FCM lo rota
	//     automáticamente, el usuario borra datos de la app
	//   · Flutter envía el token actualizado en CADA arranque de la app
	//     via PUT /users/:id/fcm-token para garantizar que siempre
	//     tengamos el token vigente
	//
	// TOKEN INVÁLIDO:
	//   Si FCM retorna "registration-token-not-registered" al intentar
	//   enviar una notificación, el backend limpia este campo (vacío).
	//   Al próximo arranque de la app Flutter enviará el nuevo token.
	//
	// MÚLTIPLES DISPOSITIVOS (no implementado actualmente):
	//   Este campo solo soporta UN dispositivo por usuario.
	//   Para múltiples dispositivos se necesitaría una tabla separada
	//   user_devices con un token por fila.
	//   Ver: NotificationService en Flutter para más detalles.
	FCMToken  *string   `json:"fcm_token,omitempty" db:"fcm_token"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// CreateUserRequest es el body del POST /users.
//
// El ID viene del cliente (UUID v4 generado offline).
// El servidor lo acepta tal cual — no genera uno nuevo.
type CreateUserRequest struct {
	ID   uuid.UUID `json:"id"   binding:"required"`
	Name string    `json:"name" binding:"required,min=2,max=50"`
}

// UpdateFCMTokenRequest es el body del PUT /users/:id/fcm-token.
//
// Flutter llama este endpoint en cada arranque de la app para
// mantener el token actualizado en el servidor.
//
// ¿Por qué en cada arranque y no solo al registrarse?
//
//	FCM puede rotar el token en cualquier momento sin avisar.
//	Si solo lo enviamos al registrarse, el token puede quedar
//	desactualizado y las notificaciones dejarán de llegar.
type UpdateFCMTokenRequest struct {
	FCMToken string `json:"fcm_token" binding:"required"`
}

// =============================================================================
// THREADS
// =============================================================================

// Thread representa una conversación entre dos usuarios.
type Thread struct {
	ID        uuid.UUID `json:"id"              db:"id"`
	UserAID   uuid.UUID `json:"user_a_id"       db:"user_a_id"`
	UserBID   uuid.UUID `json:"user_b_id"       db:"user_b_id"`
	CreatedAt time.Time `json:"created_at"      db:"created_at"`

	// LastMessage y LastMessageAt son campos calculados —
	// no existen como columnas en la tabla threads.
	// Se calculan con una subquery al listar threads de un usuario.
	LastMessage   *string    `json:"last_message,omitempty"    db:"last_message"`
	LastMessageAt *time.Time `json:"last_message_at,omitempty" db:"last_message_at"`

	// ParticipantID es el ID del otro usuario en el thread
	// (el que NO es el userId del request). Se calcula en la query.
	ParticipantID   uuid.UUID `json:"participant_id"   db:"participant_id"`
	ParticipantName string    `json:"participant_name" db:"participant_name"`
}

// CreateThreadRequest es el body del POST /threads.
type CreateThreadRequest struct {
	ID      uuid.UUID `json:"id"        binding:"required"`
	UserAID uuid.UUID `json:"user_a_id" binding:"required"`
	UserBID uuid.UUID `json:"user_b_id" binding:"required"`
}

// =============================================================================
// MENSAJES
// =============================================================================

// Message representa un mensaje dentro de un thread.
type Message struct {
	ID        uuid.UUID `json:"id"         db:"id"`
	ThreadID  uuid.UUID `json:"thread_id"  db:"thread_id"`
	SenderID  uuid.UUID `json:"sender_id"  db:"sender_id"`
	Content   string    `json:"content"    db:"content"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// CreateMessageRequest es el body del POST /messages.
//
// CreatedAt viene del cliente — es el timestamp en que el usuario
// escribió el mensaje, no cuando llegó al servidor.
// Esto preserva el orden correcto en la UI aunque haya latencia.
type CreateMessageRequest struct {
	ID        uuid.UUID `json:"id"         binding:"required"`
	ThreadID  uuid.UUID `json:"thread_id"  binding:"required"`
	SenderID  uuid.UUID `json:"sender_id"  binding:"required"`
	Content   string    `json:"content"    binding:"required,min=1"`
	CreatedAt time.Time `json:"created_at" binding:"required"`
}

// =============================================================================
// WEBSOCKET EVENTS
// =============================================================================

// WSEventType define los tipos de eventos que el servidor
// puede enviar a los clientes por WebSocket.
type WSEventType string

const (
	// WSEventNewMessage notifica a los participantes de un thread
	// que llegó un mensaje nuevo.
	WSEventNewMessage WSEventType = "new_message"

	// WSEventThreadSynced confirma al cliente que su thread
	// fue creado exitosamente en el servidor.
	WSEventThreadSynced WSEventType = "thread_synced"
)

// WSEvent es el envelope de todos los eventos WebSocket.
//
// Estructura JSON enviada al cliente:
//
//	{
//	  "type": "new_message",
//	  "data": { ... }
//	}
type WSEvent struct {
	Type WSEventType `json:"type"`
	Data any         `json:"data"`
}

// =============================================================================
// RESPONSES GENÉRICAS
// =============================================================================

// ErrorResponse es el formato estándar de error de la API.
//
//	{ "error": "mensaje descriptivo" }
type ErrorResponse struct {
	Error string `json:"error"`
}

// HealthResponse es la respuesta del endpoint GET /health.
// El ConnectivityMonitor del cliente Flutter hace ping a este endpoint.
type HealthResponse struct {
	Status string `json:"status"`
}
