package main

import (
	"context"
	"encoding/json"
	"io"
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

// DataResponse mirrors the payload from storage-service GET /data.
type DataResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	Pod     string `json:"pod"`
}

// ProcessResponse is the enriched payload returned by GET /process.
type ProcessResponse struct {
	Pod               string       `json:"pod"`
	Timestamp         string       `json:"timestamp"`
	StorageDurationMs int64        `json:"storage_duration_ms"`
	Storage           DataResponse `json:"storage"`
}

// ErrorResponse is the JSON error envelope returned on failures.
type ErrorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail,omitempty"`
	Upstream  int    `json:"upstream_status,omitempty"`
	RequestID string `json:"request_id,omitempty"`
}

// ─── shared HTTP client ─────────────────────────────────────────────────────

// newHTTPClient returns a reusable client with connection pooling tuned for
// a chatty in-cluster service mesh.
func newHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = 100
	transport.MaxIdleConnsPerHost = 100
	transport.IdleConnTimeout = 90 * time.Second

	return &http.Client{
		Timeout:   10 * time.Second,
		Transport: transport,
	}
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

func processHandler(pod, storageURL string, client *http.Client, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed,
				ErrorResponse{Error: "method not allowed"}, logger)
			return
		}

		reqID := r.Header.Get("X-Request-ID")
		logger.Info("handling /process",
			"pod", pod,
			"storage_url", storageURL,
			"request_id", reqID,
		)

		// Build upstream request with the same context so cancellation propagates.
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		upstreamReq, err := http.NewRequestWithContext(ctx, http.MethodGet, storageURL, nil)
		if err != nil {
			logger.Error("failed to build upstream request", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusInternalServerError,
				ErrorResponse{Error: "internal error", RequestID: reqID}, logger)
			return
		}
		// Forward the trace header downstream.
		upstreamReq.Header.Set("X-Request-ID", reqID)

		storageStart := time.Now()
		upstreamResp, err := client.Do(upstreamReq)
		if err != nil {
			logger.Error("upstream storage request failed",
				"error", err,
				"storage_url", storageURL,
				"request_id", reqID,
			)
			writeJSON(w, http.StatusBadGateway, ErrorResponse{
				Error:     "storage-service unavailable",
				Detail:    err.Error(),
				RequestID: reqID,
			}, logger)
			return
		}
		defer upstreamResp.Body.Close()

		body, err := io.ReadAll(upstreamResp.Body)
		if err != nil {
			logger.Error("failed to read storage response body", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusBadGateway,
				ErrorResponse{Error: "storage-service read failed", Detail: err.Error(), RequestID: reqID}, logger)
			return
		}

		// Measured after the body is fully read so it reflects the true cost.
		storageDur := time.Since(storageStart).Milliseconds()

		if upstreamResp.StatusCode != http.StatusOK {
			logger.Error("storage-service returned non-200",
				"status", upstreamResp.StatusCode,
				"body", string(body),
				"request_id", reqID,
			)
			writeJSON(w, http.StatusBadGateway, ErrorResponse{
				Error:     "storage-service error",
				Upstream:  upstreamResp.StatusCode,
				RequestID: reqID,
			}, logger)
			return
		}

		var storageData DataResponse
		if err := json.Unmarshal(body, &storageData); err != nil {
			logger.Error("failed to decode storage response", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusBadGateway,
				ErrorResponse{Error: "invalid storage response", Detail: err.Error(), RequestID: reqID}, logger)
			return
		}

		logger.Info("storage call succeeded",
			"storage_pod", storageData.Pod,
			"storage_duration_ms", storageDur,
			"request_id", reqID,
		)

		writeJSON(w, http.StatusOK, ProcessResponse{
			Pod:               pod,
			Timestamp:         time.Now().UTC().Format(time.RFC3339Nano),
			StorageDurationMs: storageDur,
			Storage:           storageData,
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
	storageURL := getEnv("STORAGE_SERVICE_URL", "http://storage-service:8080/data")

	logger.Info("processor-service starting",
		"pod", pod,
		"port", port,
		"storage_url", storageURL,
	)

	client := newHTTPClient()

	mux := http.NewServeMux()
	mux.HandleFunc("/process", processHandler(pod, storageURL, client, logger))
	mux.HandleFunc("/healthz", healthzHandler)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           loggingMiddleware(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown on SIGTERM / SIGINT (important for rolling updates).
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)

	serverErr := make(chan error, 1)
	go func() {
		logger.Info("processor-service listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serverErr <- err
		}
	}()

	select {
	case err := <-serverErr:
		logger.Error("server error", "error", err)
		os.Exit(1)
	case sig := <-quit:
		logger.Info("processor-service shutting down", "signal", sig.String())
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("processor-service stopped")
}
