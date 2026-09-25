package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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

// newRequestID generates a random 8-byte hex string used as X-Request-ID.
func newRequestID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(b)
}

// writeJSON writes v as a JSON response with the given status code.
// Using this instead of http.Error keeps the Content-Type consistently JSON.
func writeJSON(w http.ResponseWriter, status int, v any, logger *slog.Logger) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logger.Error("failed to encode response", "error", err)
	}
}

// ─── response structs ───────────────────────────────────────────────────────

// DataResponse mirrors storage-service GET /data.
type DataResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	Pod     string `json:"pod"`
}

// ProcessResponse mirrors processor-service GET /process.
type ProcessResponse struct {
	Pod               string       `json:"pod"`
	Timestamp         string       `json:"timestamp"`
	StorageDurationMs int64        `json:"storage_duration_ms"`
	Storage           DataResponse `json:"storage"`
}

// PingResponse is the aggregated payload returned by GET /ping.
type PingResponse struct {
	Status          string          `json:"status"`
	GatewayPod      string          `json:"gateway_pod"`
	RequestID       string          `json:"request_id"`
	TotalDurationMs int64           `json:"total_duration_ms"`
	Processor       ProcessResponse `json:"processor"`
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
		Timeout:   15 * time.Second,
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

// requestIDMiddleware ensures every request carries an X-Request-ID.
// The gateway is the entry point of the chain, so it mints the ID here (unless
// the caller already supplied one) and stores it back on the request headers so
// both the access log and the handler observe the same value.
func requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
			r.Header.Set("X-Request-ID", reqID)
		}
		// Expose it to the caller so they can correlate logs.
		w.Header().Set("X-Request-ID", reqID)
		next.ServeHTTP(w, r)
	})
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

func pingHandler(gatewayPod, processorURL string, client *http.Client, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed,
				ErrorResponse{Error: "method not allowed"}, logger)
			return
		}

		// Guaranteed to be present by requestIDMiddleware.
		reqID := r.Header.Get("X-Request-ID")

		logger.Info("handling /ping",
			"gateway_pod", gatewayPod,
			"processor_url", processorURL,
			"request_id", reqID,
		)

		start := time.Now()

		ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
		defer cancel()

		upstreamReq, err := http.NewRequestWithContext(ctx, http.MethodGet, processorURL, nil)
		if err != nil {
			logger.Error("failed to build upstream request", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusInternalServerError,
				ErrorResponse{Error: "internal error", RequestID: reqID}, logger)
			return
		}
		upstreamReq.Header.Set("X-Request-ID", reqID)

		upstreamResp, err := client.Do(upstreamReq)
		if err != nil {
			logger.Error("upstream processor request failed",
				"error", err,
				"processor_url", processorURL,
				"request_id", reqID,
			)
			writeJSON(w, http.StatusBadGateway, ErrorResponse{
				Error:     "processor-service unavailable",
				Detail:    err.Error(),
				RequestID: reqID,
			}, logger)
			return
		}
		defer upstreamResp.Body.Close()

		body, err := io.ReadAll(upstreamResp.Body)
		if err != nil {
			logger.Error("failed to read processor response body", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusBadGateway,
				ErrorResponse{Error: "processor-service read failed", Detail: err.Error(), RequestID: reqID}, logger)
			return
		}

		if upstreamResp.StatusCode != http.StatusOK {
			logger.Error("processor-service returned non-200",
				"status", upstreamResp.StatusCode,
				"body", string(body),
				"request_id", reqID,
			)
			writeJSON(w, http.StatusBadGateway, ErrorResponse{
				Error:     "processor-service error",
				Upstream:  upstreamResp.StatusCode,
				RequestID: reqID,
			}, logger)
			return
		}

		var processorData ProcessResponse
		if err := json.Unmarshal(body, &processorData); err != nil {
			logger.Error("failed to decode processor response", "error", err, "request_id", reqID)
			writeJSON(w, http.StatusBadGateway,
				ErrorResponse{Error: "invalid processor response", Detail: err.Error(), RequestID: reqID}, logger)
			return
		}

		// Measured after the body is fully read so it reflects the true
		// end-to-end cost of the downstream chain.
		totalDur := time.Since(start).Milliseconds()

		logger.Info("ping chain completed",
			"gateway_pod", gatewayPod,
			"processor_pod", processorData.Pod,
			"storage_pod", processorData.Storage.Pod,
			"total_duration_ms", totalDur,
			"request_id", reqID,
		)

		writeJSON(w, http.StatusOK, PingResponse{
			Status:          "ok",
			GatewayPod:      gatewayPod,
			RequestID:       reqID,
			TotalDurationMs: totalDur,
			Processor:       processorData,
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

	gatewayPod := getEnv("HOSTNAME", "unknown")
	port := getEnv("PORT", "8080")
	processorURL := getEnv("PROCESSOR_SERVICE_URL", "http://processor-service:8080/process")

	logger.Info("gateway-service starting",
		"pod", gatewayPod,
		"port", port,
		"processor_url", processorURL,
	)

	client := newHTTPClient()

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", pingHandler(gatewayPod, processorURL, client, logger))
	mux.HandleFunc("/healthz", healthzHandler)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           requestIDMiddleware(loggingMiddleware(logger, mux)),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown on SIGTERM / SIGINT (important for rolling updates).
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)

	serverErr := make(chan error, 1)
	go func() {
		logger.Info("gateway-service listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serverErr <- err
		}
	}()

	// Exit on either a fatal listen error or a shutdown signal.
	select {
	case err := <-serverErr:
		logger.Error("server error", "error", err)
		os.Exit(1)
	case sig := <-quit:
		logger.Info("gateway-service shutting down", "signal", sig.String())
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}

	logger.Info("gateway-service stopped")
}
