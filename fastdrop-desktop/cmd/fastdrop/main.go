// Command fastdrop is the Windows desktop server.
// It wires every subsystem together and serves HTTP + WS on a single port.
package main

import (
	"context"
	"embed"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"fastdrop-desktop/internal/api"
	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/discovery"
	"fastdrop-desktop/internal/pairing"
	"fastdrop-desktop/internal/session"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
	"fastdrop-desktop/internal/websocket"

	gws "github.com/gorilla/websocket"
)

//go:embed all:webdist
var webAssets embed.FS

func main() {
	cfgPath := flag.String("config", "", "path to config.json (defaults to %APPDATA%/FastDrop/config.json)")
	flag.Parse()

	cfg, err := loadOrInitConfig(*cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Subsystem setup.
	db, err := database.Open(cfg.Server.DatabasePath)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer db.Close()

	// Invalidate any sessions from a previous run (spec §7.1).
	if n, err := db.RevokeAllSessions(context.Background()); err == nil && n > 0 {
		log.Printf("[startup] revoked %d stale sessions", n)
	}

	store, err := storage.NewManager(cfg.Storage.DownloadDirectory)
	if err != nil {
		log.Fatalf("storage: %v", err)
	}
	pairMgr := pairing.NewManager(time.Duration(cfg.Security.PairTokenTTLSeconds) * time.Second)
	sessMgr := session.NewManager(db, time.Duration(cfg.Security.SessionTTLSeconds)*time.Second)
	transferMgr := transfer.NewManager(db, cfg.Transfer.ChunkSize, nil)
	wsHub := websocket.NewHub(&websocket.SessionValidator{M: sessMgr})

	// Choose discovery implementation.
	var publisher discovery.DiscoveryPublisher = discovery.NoopPublisher{}
	if cfg.Discovery.MdnsEnabled {
		publisher = discovery.NewMdnsPublisher()
	}

	apiSrv := &api.Server{
		Cfg: cfg, DB: db,
		Pairing: pairMgr, Session: sessMgr,
		Transfer: transferMgr, Storage: store,
		WSHub: wsHub,
	}

	// Background tasks.
	rootCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go wsHub.Run(rootCtx)
	go pairMgrCleanupLoop(rootCtx, pairMgr)
	go sessionExpiryLoop(rootCtx, db)

	// Publish on mDNS (Phase 2).
	host, port := resolveBindAddress(cfg)
	if err := publisher.Start(rootCtx, discovery.ServiceInfo{
		DeviceID: "windows-local", DeviceName: cfg.Server.DeviceName,
		Host: host, Port: port, ProtocolVersion: 1, Platform: "windows",
	}); err != nil {
		log.Printf("[discovery] start failed: %v (continuing without mDNS)", err)
	}
	defer publisher.Stop()

	// Router.
	mux := http.NewServeMux()
	mux.Handle("/api/", api.New(apiSrv))
	mux.Handle("/ws/v1", wsHandler(wsHub, sessMgr))
	mux.Handle("/", webUIHandler())

	addr := fmt.Sprintf(":%d", cfg.Server.Port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           requestLogger(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Print LAN IPs so the user knows where to point their phone.
	lanIPs := lanIPAddresses()
	if len(lanIPs) == 0 {
		log.Printf("[startup] no LAN IPv4 detected; UI will be at http://127.0.0.1:%d", cfg.Server.Port)
	} else {
		for _, ip := range lanIPs {
			log.Printf("[startup] listening on http://%s:%d", ip, cfg.Server.Port)
		}
	}

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Wait for interrupt.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("[shutdown] interrupt received, draining...")
	publisher.Stop()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutCancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("[shutdown] error: %v", err)
	}
	cancel()
	log.Println("[shutdown] bye")
}

// wsHandler returns the /ws/v1 handler.
func wsHandler(hub *websocket.Hub, sessMgr *session.Manager) http.HandlerFunc {
	up := gws.Upgrader{
		HandshakeTimeout: 5 * time.Second,
		CheckOrigin:      func(r *http.Request) bool { return true },
	}
	return func(w http.ResponseWriter, r *http.Request) {
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		// Pre-auth from headers if possible.
		var pre *websocket.PreAuth
		if h := r.Header.Get("Authorization"); len(h) > 7 && h[:7] == "Bearer " {
			sessID := r.Header.Get("X-Session-Id")
			if sessID != "" {
				row, err := sessMgr.Validate(r.Context(), sessID, h[7:], clientIP(r), true)
				if err == nil {
					pre = &websocket.PreAuth{SessionID: row.ID, DeviceID: row.DeviceID}
				}
			}
		}
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		_ = hub.HandleConn(ctx, conn, clientIP(r), pre)
	}
}

// webUIHandler serves the embedded Vue build at "/" (SPA fallback).
func webUIHandler() http.Handler {
	dist, err := fs.Sub(webAssets, "webdist")
	if err != nil {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprintln(w, "web/dist not built. Run `npm run build` in web/.")
		})
	}
	fileServer := http.FileServer(http.FS(dist))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// SPA fallback for unknown routes.
		if r.URL.Path != "/" {
			cleanPath := strings.TrimPrefix(r.URL.Path, "/")
			if _, err := webAssets.Open("webdist/" + cleanPath); err != nil {
				r2 := r.Clone(r.Context())
				r2.URL.Path = "/"
				fileServer.ServeHTTP(w, r2)
				return
			}
		}
		fileServer.ServeHTTP(w, r)
	})
}

// requestLogger is a minimal access logger.
func requestLogger(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h.ServeHTTP(w, r)
		log.Printf("%s %s %s %s", r.Method, r.URL.Path, r.RemoteAddr, time.Since(start))
	})
}

// clientIP strips the port from RemoteAddr.
func clientIP(r *http.Request) string {
	host := r.RemoteAddr
	if i := lastIndexByte(host, ':'); i > 0 {
		host = host[:i]
	}
	return host
}

func lastIndexByte(s string, b byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// pairMgrCleanupLoop periodically evicts expired pair tokens + requests.
func pairMgrCleanupLoop(ctx context.Context, m *pairing.Manager) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.Cleanup()
		}
	}
}

// sessionExpiryLoop purges old sessions every 10 minutes.
func sessionExpiryLoop(ctx context.Context, db *database.DB) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := db.DeleteExpiredSessions(ctx, database.Now())
			if err == nil && n > 0 {
				log.Printf("[session] purged %d expired rows", n)
			}
		}
	}
}
