package main

import (
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jeethsuresh/haven/backend/internal/gravitas"
)

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func main() {
	dev := os.Getenv("HAVEN_DEV") == "1"
	listen := env("HAVEN_LISTEN", "127.0.0.1:8090")
	appURL := strings.TrimSuffix(env("HAVEN_APP_URL", "http://127.0.0.1:8090"), "/")
	if dev {
		host, _, err := net.SplitHostPort(listen)
		if err != nil || (host != "127.0.0.1" && host != "::1" && host != "localhost") {
			log.Fatal("HAVEN_DEV requires a loopback listener")
		}
	}
	store, err := openStore(env("HAVEN_DATA", ".local"))
	if err != nil {
		log.Fatal(err)
	}
	// Retire the old derived cache; thumbnail bytes now live only on devices.
	if err := os.RemoveAll(filepath.Join(env("HAVEN_DATA", ".local"), "thumbnails")); err != nil {
		log.Fatal(err)
	}
	s := &Server{store: store, dev: dev, appURL: appURL, dataDir: env("HAVEN_DATA", ".local"), webDir: env("HAVEN_WEB", "../client/build/web"), pending: map[string]pendingLogin{}, stunURLs: []string{}}
	if !dev {
		s.iam, err = gravitas.New(env("GRAVITAS_ISSUER", "https://gravitas.cool"), appURL, os.Getenv("GRAVITAS_SESSION_KEY"))
		if err != nil {
			log.Fatal(err)
		}
	}
	for _, raw := range strings.Split(os.Getenv("HAVEN_STUN_URLS"), ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if !strings.HasPrefix(raw, "stun:") || strings.ContainsAny(raw, "@ \r\n") {
			log.Fatal("Only stun: URLs are allowed; TURN is disabled")
		}
		s.stunURLs = append(s.stunURLs, raw)
	}
	server := &http.Server{Addr: listen, Handler: s.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	log.Printf("Haven listening on %s (development=%t)", listen, dev)
	log.Fatal(server.ListenAndServe())
}
