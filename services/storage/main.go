package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// ─── helpers ────────────────────────────────────────────────────────────────

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// writeJSON writes v as a JSON response with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any, logger *slog.Logger) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logger.Error("failed to encode response", "error", err)
	}
}

// ─── response structs ───────────────────────────────────────────────────────

// DataResponse is the payload returned by GET /data.
type DataResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	Pod     string `json:"pod"`
}

// ErrorResponse is the JSON error envelope returned on failures.
type ErrorResponse struct {
	Error string `json:"error"`
}

// ─── middleware ─────────────────────────────────────────────────────────────

// responseWriter wraps http.ResponseWriter to capture the status code.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// loggingMiddleware logs every request with method, path, status, duration and
// the X-Request-ID so the full chain is traceable via kubectl logs.
func loggingMiddleware(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rw.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"request_id", r.Header.Get("X-Request-ID"),
		)
	})
}

// ─── handlers ───────────────────────────────────────────────────────────────

func dataHandler(pod string, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed,
				ErrorResponse{Error: "method not allowed"}, logger)
			return
		}

		logger.Info("serving /data",
			"pod", pod,
			"request_id", r.Header.Get("X-Request-ID"),
		)

		writeJSON(w, http.StatusOK, DataResponse{
			Status:  "ok",
			Message: "Data retrieved from storage",
			Pod:     pod,
		}, logger)
	}
}

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

// ─── main ───────────────────────────────────────────────────────────────────

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	pod := getEnv("HOSTNAME", "unknown")
	port := getEnv("PORT", "8080")

	logger.Info("storage-service starting",
		"pod", pod,
		"port", port,
	)

	mux := http.NewServeMux()
	mux.HandleFunc("/data", dataHandler(pod, logger))
	mux.HandleFunc("/healthz", healthzHandler)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           loggingMiddleware(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown on SIGTERM / SIGINT (important for rolling updates).
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)

	serverErr := make(chan error, 1)
	go func() {
		logger.Info("storage-service listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serverErr <- err
		}
	}()

	select {
	case err := <-serverErr:
		logger.Error("server error", "error", err)
		os.Exit(1)
	case sig := <-quit:
		logger.Info("storage-service shutting down", "signal", sig.String())
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("storage-service stopped")
}
