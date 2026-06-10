// Entry point del servidor ChatSync.
//
// SECUENCIA DE ARRANQUE:
//   1. Cargar variables de entorno desde .env
//   2. Conectar a PostgreSQL
//   3. Crear el WebSocket Hub
//   4. Crear los handlers (inyectando DB y Hub)
//   5. Configurar las rutas de Gin
//   6. Iniciar el servidor HTTP
//
// RUTAS:
//   GET  /health                          → ping del ConnectivityMonitor de Flutter
//   POST /users                           → registrar usuario
//   GET  /users/search?q=                 → buscar usuarios por nombre
//   POST /threads                         → crear thread
//   GET  /threads?userId=&since=          → listar threads del usuario
//   POST /messages                        → enviar mensaje
//   GET  /messages/:threadId?since=       → obtener mensajes de un thread
//   GET  /ws?userId=                      → conexión WebSocket

package main

import (
	"log"
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/db"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/handlers"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/models"
	"github.com/raulurtecho/chatsync/chat_sync_backend/internal/ws"
)

func main() {
	// =========================================================================
	// PASO 1 — Cargar variables de entorno
	// =========================================================================
	// godotenv carga el archivo .env en las variables de entorno del proceso.
	// Si el archivo no existe (ej: en producción donde se usan env vars reales),
	// simplemente se ignora — no es un error fatal.
	if err := godotenv.Load(); err != nil {
		log.Println("[ENV] Archivo .env no encontrado, usando variables del sistema")
	}

	port := getEnv("PORT", "8080")
	databaseURL := getEnv("DATABASE_URL", "")
	environment := getEnv("ENV", "development")

	if databaseURL == "" {
		log.Fatal("[DB] DATABASE_URL no configurada")
	}

	// =========================================================================
	// PASO 2 — Conectar a PostgreSQL
	// =========================================================================
	database, err := db.Connect(databaseURL)
	if err != nil {
		log.Fatalf("[DB] Error conectando a PostgreSQL: %v", err)
	}
	defer database.Close()
	log.Println("[DB] Conectado a PostgreSQL correctamente")

	// =========================================================================
	// PASO 3 — Crear el WebSocket Hub
	// =========================================================================
	// El Hub gestiona todas las conexiones WebSocket activas.
	// Se crea antes que los handlers porque MessagesHandler lo necesita.
	hub := ws.NewHub()

	// =========================================================================
	// PASO 4 — Crear handlers con inyección de dependencias
	// =========================================================================
	usersHandler := handlers.NewUsersHandler(database)
	threadsHandler := handlers.NewThreadsHandler(database)
	messagesHandler := handlers.NewMessagesHandler(database, hub)

	// =========================================================================
	// PASO 5 — Configurar Gin
	// =========================================================================
	if environment == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.Default()

	// Middleware CORS — permite requests desde el emulador/dispositivo Flutter.
	// En producción restringir a los orígenes específicos de la app.
	router.Use(corsMiddleware())

	// =========================================================================
	// PASO 6 — Registrar rutas
	// =========================================================================

	// Health check — usado por ConnectivityMonitor de Flutter para
	// verificar si el servidor está disponible (ping real)
	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, models.HealthResponse{Status: "ok"})
	})

	// WebSocket — Flutter se conecta aquí para recibir mensajes en tiempo real
	router.GET("/ws", hub.HandleWebSocket)

	// API v1
	api := router.Group("/")
	{
		// Usuarios
		api.POST("/users", usersHandler.CreateUser)
		api.GET("/users/search", usersHandler.SearchUsers)

		// Threads
		api.POST("/threads", threadsHandler.CreateThread)
		api.GET("/threads", threadsHandler.GetThreads)

		// Mensajes
		api.POST("/messages", messagesHandler.CreateMessage)
		api.GET("/messages/:threadId", messagesHandler.GetMessages)
	}

	// =========================================================================
	// PASO 7 — Iniciar el servidor
	// =========================================================================
	addr := ":" + port
	log.Printf("[SERVER] ChatSync corriendo en http://localhost%s (ENV=%s)", addr, environment)
	log.Printf("[SERVER] WebSocket disponible en ws://localhost%s/ws?userId=UUID", addr)

	if err := router.Run(addr); err != nil {
		log.Fatalf("[SERVER] Error iniciando servidor: %v", err)
	}
}

// =============================================================================
// HELPERS
// =============================================================================

// getEnv retorna el valor de una variable de entorno o un default.
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// corsMiddleware configura los headers CORS para permitir requests
// desde el cliente Flutter (emulador Android: 10.0.2.2, iOS: localhost).
//
// En producción reemplazar con orígenes específicos.
func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers",
			"Origin, Content-Type, X-User-Id, X-Idempotency-Key")

		// Responder preflight requests de inmediato
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}
