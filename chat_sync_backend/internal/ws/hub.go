// internal/ws/hub.go
//
// WebSocket Hub — gestor central de conexiones en tiempo real.
//
// RESPONSABILIDAD:
//   · Registrar clientes cuando se conectan por WebSocket
//   · Desregistrar clientes cuando se desconectan
//   · Enviar eventos a un usuario específico (por userID)
//   · Manejar múltiples conexiones del mismo usuario
//     (mismo usuario en dos dispositivos)
//
// ARQUITECTURA:
//
//   Cliente Flutter ←──WebSocket──→ Hub ←── MessagesHandler
//
//   El Hub mantiene un mapa: userID → []*Client
//   Cuando MessagesHandler llama SendToUser(userID, event),
//   el Hub encuentra todas las conexiones activas de ese usuario
//   y les envía el evento.
//
// CONCURRENCIA:
//   El Hub usa un mutex (sync.RWMutex) para proteger el mapa de clientes
//   de accesos concurrentes — múltiples goroutines pueden estar
//   registrando/desregistrando clientes simultáneamente.
//
//   Cada cliente tiene su propia goroutine writePump que consume
//   de un canal send y escribe al WebSocket. Esto evita que dos
//   goroutines escriban al mismo WebSocket simultáneamente.

package ws

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
)

// Configuración del WebSocket
const (
	// Tiempo máximo para escribir un mensaje al cliente
	writeWait = 10 * time.Second

	// Tiempo máximo para leer el próximo pong del cliente
	pongWait = 60 * time.Second

	// Intervalo de ping (debe ser menor que pongWait)
	pingPeriod = (pongWait * 9) / 10

	// Tamaño máximo del mensaje entrante
	maxMessageSize = 512

	// Tamaño del buffer del canal send por cliente
	sendBufferSize = 256
)

// upgrader configura la actualización HTTP → WebSocket.
//
// CheckOrigin retorna true para cualquier origen — en producción
// debería validar el origen del request.
var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // En producción: validar r.Header.Get("Origin")
	},
}

// Client representa una conexión WebSocket activa de un usuario.
type Client struct {
	// userID identifica al usuario dueño de esta conexión
	userID uuid.UUID

	// conn es la conexión WebSocket subyacente
	conn *websocket.Conn

	// send es el canal por donde llegan los mensajes a enviar.
	// Cada mensaje se serializa a JSON y se escribe al WebSocket.
	// El canal es buffereado para no bloquear al sender si el
	// cliente está lento consumiendo.
	send chan []byte

	// hub es la referencia al Hub para poder desregistrarse
	hub *Hub
}

// Hub gestiona todas las conexiones WebSocket activas.
type Hub struct {
	// clients mapea userID → lista de conexiones activas.
	// Un usuario puede tener múltiples conexiones (varios dispositivos).
	clients map[uuid.UUID][]*Client

	// mu protege el mapa clients de accesos concurrentes
	mu sync.RWMutex
}

// NewHub crea una nueva instancia del Hub.
func NewHub() *Hub {
	return &Hub{
		clients: make(map[uuid.UUID][]*Client),
	}
}

// =============================================================================
// GESTIÓN DE CLIENTES
// =============================================================================

// register agrega un cliente al Hub.
func (h *Hub) register(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[client.userID] = append(h.clients[client.userID], client)
	log.Printf("[WS] Cliente conectado: userID=%s, total conexiones=%d",
		client.userID, len(h.clients[client.userID]))
}

// unregister elimina un cliente del Hub y cierra su canal send.
func (h *Hub) unregister(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	connections := h.clients[client.userID]
	for i, c := range connections {
		if c == client {
			// Eliminar este cliente de la lista
			h.clients[client.userID] = append(connections[:i], connections[i+1:]...)
			close(client.send)
			break
		}
	}

	// Limpiar la entrada del mapa si no quedan conexiones para este usuario
	if len(h.clients[client.userID]) == 0 {
		delete(h.clients, client.userID)
	}

	log.Printf("[WS] Cliente desconectado: userID=%s", client.userID)
}

// SendToUser envía un evento WebSocket a todas las conexiones activas
// de un usuario específico.
//
// Se llama desde MessagesHandler cuando llega un mensaje nuevo.
// Si el usuario no está conectado, se ignora silenciosamente —
// el SyncEngine de Flutter hará delta sync al reconectar.
func (h *Hub) SendToUser(userID uuid.UUID, event models.WSEvent) {
	// Serializar el evento a JSON una sola vez
	data, err := json.Marshal(event)
	if err != nil {
		log.Printf("[WS] Error serializando evento: %v", err)
		return
	}

	h.mu.RLock()
	connections := h.clients[userID]
	h.mu.RUnlock()

	// Enviar a cada conexión activa del usuario
	for _, client := range connections {
		select {
		case client.send <- data:
			// Mensaje encolado exitosamente
		default:
			// Canal lleno — cliente demasiado lento o desconectado
			// Desregistrar en una goroutine para no bloquear el RLock
			go h.unregister(client)
		}
	}
}

// =============================================================================
// HANDLER HTTP — UPGRADE A WEBSOCKET
// =============================================================================

// HandleWebSocket maneja GET /ws?userId={uuid}
//
// Actualiza la conexión HTTP a WebSocket y registra el cliente en el Hub.
// El userId viene del query param porque los headers HTTP no están
// disponibles después del upgrade en todos los clientes.
//
// Flutter se conecta así:
//
//	ws://host:8080/ws?userId=uuid
func (h *Hub) HandleWebSocket(c *gin.Context) {
	// Obtener el userId del query param
	userIDStr := c.Query("userId")
	if userIDStr == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "userId requerido",
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

	// Actualizar HTTP → WebSocket
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("[WS] Error en upgrade: %v", err)
		return
	}

	// Crear el cliente y registrarlo en el Hub
	client := &Client{
		userID: userID,
		conn:   conn,
		send:   make(chan []byte, sendBufferSize),
		hub:    h,
	}

	h.register(client)

	// Lanzar la goroutine de escritura
	// readPump corre en la goroutine actual y bloquea hasta que
	// el cliente se desconecta.
	go client.writePump()
	client.readPump()
}

// =============================================================================
// PUMPS — GOROUTINES DE LECTURA Y ESCRITURA
// =============================================================================

// readPump lee mensajes del WebSocket del cliente.
//
// En este proyecto el cliente Flutter no envía mensajes por WS
// (solo los recibe), pero readPump es necesaria para:
//
//	· Detectar cuando el cliente se desconecta (EOF, error)
//	· Responder a los pings del servidor con pongs automáticos
//	· Establecer el deadline de lectura para detectar clientes inactivos
//
// readPump corre en la goroutine del handler y bloquea hasta
// que el cliente se desconecta.
func (c *Client) readPump() {
	defer func() {
		c.hub.unregister(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))

	// Cada vez que llega un pong, extender el deadline
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	// Leer y descartar mensajes entrantes del cliente
	// (no los procesamos, solo mantenemos la conexión viva)
	for {
		_, _, err := c.conn.ReadMessage()
		if err != nil {
			// Desconexión normal o error — salir del loop
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway,
				websocket.CloseAbnormalClosure,
			) {
				log.Printf("[WS] Error inesperado: %v", err)
			}
			break
		}
	}
}

// writePump escribe mensajes del canal send al WebSocket.
//
// Corre en su propia goroutine para cada cliente.
// Garantiza que solo una goroutine escribe al WebSocket a la vez
// (gorilla/websocket no es thread-safe para escrituras concurrentes).
//
// También envía pings periódicos para detectar clientes desconectados
// que no enviaron un cierre limpio (ej: app cerrada abruptamente).
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		// Mensaje a enviar al cliente
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))

			if !ok {
				// Canal cerrado — el Hub desregistró este cliente
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			// Escribir el mensaje JSON al WebSocket
			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)

			// Optimización: si hay más mensajes en el canal,
			// enviarlos en el mismo frame WebSocket separados por newline
			n := len(c.send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-c.send)
			}

			if err := w.Close(); err != nil {
				return
			}

		// Ping periódico para mantener la conexión viva
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				// Cliente no respondió al ping — desconectado
				return
			}
		}
	}
}
