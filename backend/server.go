package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jeethsuresh/haven/backend/internal/gravitas"
)

type Signal struct {
	Seq        int64           `json:"seq"`
	TransferID string          `json:"transfer_id"`
	To         string          `json:"-"`
	Type       string          `json:"type"`
	Data       json.RawMessage `json:"data"`
	Created    int64           `json:"-"`
}
type Server struct {
	store                   *Store
	iam                     *gravitas.Client
	dev                     bool
	appURL, dataDir, webDir string
	stunURLs                []string
	mu                      sync.Mutex
	pending                 map[string]pendingLogin
	signals                 []Signal
	seq                     int64
}

func reply(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, code int, message string) {
	reply(w, code, map[string]string{"error": message})
}
func decode(w http.ResponseWriter, r *http.Request, out any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(out) != nil || d.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid_or_oversized_json")
		return false
	}
	return true
}
func (s *Server) actor(st *State, session Session) (Device, error) {
	d, ok := st.Devices[session.DeviceID]
	if !ok || d.Revoked || d.Account != session.Account {
		return Device{}, errors.New("device_required")
	}
	return d, nil
}
func (s *Server) handler() http.Handler {
	m := http.NewServeMux()
	s.authRoutes(m)
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]string{"status": "ok", "app": "haven", "version": "0.1.0"})
	})
	m.HandleFunc("GET /api/config", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]any{"dev": s.dev, "stun_urls": s.stunURLs, "turn": false, "chunk_size": 16384, "namespaces": []string{"media", "file", "contact", "note"}})
	})
	m.HandleFunc("GET /api/me", func(w http.ResponseWriter, r *http.Request) {
		a, _, ok := s.authorize(w, r)
		if ok {
			reply(w, 200, map[string]any{"account": a.Account, "device_id": a.DeviceID, "expires": a.Expires})
		}
	})
	m.HandleFunc("GET /api/devices", func(w http.ResponseWriter, r *http.Request) {
		a, _, ok := s.authorize(w, r)
		if !ok {
			return
		}
		s.store.mu.Lock()
		defer s.store.mu.Unlock()
		out := []Device{}
		for _, d := range s.store.state.Devices {
			if d.Account == a.Account {
				out = append(out, d)
			}
		}
		reply(w, 200, out)
	})
	m.HandleFunc("POST /api/devices", s.register)
	m.HandleFunc("POST /api/devices/heartbeat", func(w http.ResponseWriter, r *http.Request) {
		a, _, ok := s.authorize(w, r)
		if !ok {
			return
		}
		err := s.store.update(func(st *State) error {
			d, e := s.actor(st, a)
			if e != nil {
				return e
			}
			d.Seen = time.Now().Unix()
			st.Devices[d.ID] = d
			for _, asset := range st.Assets {
				if asset.Account == a.Account {
					plan(st, asset)
				}
			}
			return nil
		})
		if err != nil {
			fail(w, 400, "heartbeat_failed")
			return
		}
		reply(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("DELETE /api/devices/{id}", func(w http.ResponseWriter, r *http.Request) {
		a, _, ok := s.authorize(w, r)
		if !ok {
			return
		}
		err := s.store.update(func(st *State) error {
			d, exists := st.Devices[r.PathValue("id")]
			if !exists || d.Account != a.Account {
				return errors.New("not_found")
			}
			d.Revoked = true
			st.Devices[d.ID] = d
			for k, t := range st.Transfers {
				if t.From == d.ID || t.To == d.ID {
					t.Status = "superseded"
					st.Transfers[k] = t
				}
			}
			for _, asset := range st.Assets {
				if asset.Account == a.Account {
					plan(st, asset)
				}
			}
			return nil
		})
		if err != nil {
			fail(w, 404, "not_found")
			return
		}
		reply(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("GET /api/assets", s.assets)
	m.HandleFunc("POST /api/assets", s.publish)
	m.HandleFunc("POST /api/thumbnail-requests", s.requestThumbnail)
	m.HandleFunc("POST /api/reports", s.reportDevice)
	m.HandleFunc("GET /api/reports", s.reports)
	m.HandleFunc("GET /api/transfers", s.transfers)
	m.HandleFunc("POST /api/transfers/{id}", s.updateTransfer)
	m.HandleFunc("POST /api/signals", s.signal)
	m.HandleFunc("GET /api/signals", s.pollSignals)
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			fail(w, 404, "not_found")
			return
		}
		if _, err := os.Stat(filepath.Join(s.webDir, "index.html")); err != nil {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = io.WriteString(w, `<title>Haven</title><h1>Haven backend is ready</h1><p>Build the Flutter web viewer with <code>cd client &amp;&amp; flutter build web</code>, then restart the backend.</p>`)
			return
		}
		http.FileServer(http.Dir(s.webDir)).ServeHTTP(w, r)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		m.ServeHTTP(w, r)
	})
}
func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	a, key, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var body struct {
		Name     string   `json:"name"`
		Platform string   `json:"platform"`
		Roles    []string `json:"roles"`
	}
	if !decode(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Name) == "" || len(body.Name) > 100 || len(body.Roles) < 1 || len(body.Roles) > 3 || !slices.Contains([]string{"android", "linux", "windows", "macos", "web"}, body.Platform) {
		fail(w, 400, "invalid_device")
		return
	}
	seen := map[string]bool{}
	for _, role := range body.Roles {
		if !slices.Contains([]string{"viewer", "source", "sink"}, role) || seen[role] {
			fail(w, 400, "invalid_roles")
			return
		}
		seen[role] = true
	}
	if !seen["viewer"] || (body.Platform == "web" && (seen["sink"] || seen["source"])) || (body.Platform == "android" && seen["sink"]) {
		fail(w, 400, "unsupported_role_for_platform")
		return
	}
	var device Device
	err := s.store.update(func(st *State) error {
		id := a.DeviceID
		if id == "" {
			id = randomID()
		}
		if old, exists := st.Devices[id]; exists && old.Revoked {
			return errors.New("revoked")
		}
		device = Device{ID: id, Account: a.Account, Name: body.Name, Platform: body.Platform, Roles: body.Roles, Seen: time.Now().Unix()}
		st.Devices[id] = device
		a.DeviceID = id
		st.Sessions[key] = a
		for k, t := range st.Transfers {
			if (t.From == id && !device.has("source") && !device.has("sink")) || (t.To == id && t.Purpose != "thumbnail" && !device.has("sink")) {
				t.Status = "superseded"
				st.Transfers[k] = t
			}
		}
		for _, asset := range st.Assets {
			if asset.Account == a.Account {
				plan(st, asset)
			}
		}
		return nil
	})
	if err != nil {
		fail(w, 500, "registration_failed")
		return
	}
	reply(w, 200, device)
}
func (s *Server) assets(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	out := []map[string]any{}
	for _, asset := range s.store.state.Assets {
		if asset.Account != a.Account {
			continue
		}
		replicas := []Replica{}
		copies := 0
		for _, replica := range s.store.state.Replicas {
			d := s.store.state.Devices[replica.DeviceID]
			if replica.AssetID == asset.ID && !d.Revoked {
				replicas = append(replicas, replica)
				if replica.RevisionID == asset.head().ID && d.has("sink") {
					copies++
				}
			}
		}
		out = append(out, map[string]any{"asset": asset, "replicas": replicas, "sink_copies": copies})
	}
	reply(w, 200, out)
}
func (s *Server) publish(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var body struct {
		ID       string `json:"id"`
		Base     string `json:"base"`
		Kind     string `json:"kind"`
		Path     string `json:"path"`
		MIME     string `json:"mime"`
		SHA256   string `json:"sha256"`
		Size     int64  `json:"size"`
		Captured int64  `json:"captured"`
	}
	if !decode(w, r, &body) {
		return
	}
	if !validPath(body.Kind, body.Path) || !digestPattern.MatchString(body.SHA256) || body.Size < 0 || body.Size > 1<<50 || len(body.MIME) > 128 || (body.ID != "" && !idPattern.MatchString(body.ID)) {
		fail(w, 400, "invalid_manifest")
		return
	}
	if body.Kind == "media" && !strings.HasPrefix(body.MIME, "image/") && !strings.HasPrefix(body.MIME, "video/") && !strings.HasPrefix(body.MIME, "audio/") {
		fail(w, 400, "invalid_media_type")
		return
	}
	var out Asset
	err := s.store.update(func(st *State) error {
		d, e := s.actor(st, a)
		if e != nil || (!d.has("source") && !d.has("sink")) {
			return errors.New("forbidden")
		}
		id := body.ID
		if id == "" {
			id = randomID()
		}
		old, exists := st.Assets[id]
		if exists && old.Account != a.Account {
			return errors.New("forbidden")
		}
		if exists && old.Kind != body.Kind {
			return errors.New("invalid_kind")
		}
		conflict := ""
		if (exists && body.Base != old.head().ID) || (!exists && body.Base != "") {
			if !exists {
				return errors.New("invalid_base")
			}
			conflict = id
			id = randomID()
			ext := path.Ext(body.Path)
			body.Path = strings.TrimSuffix(body.Path, ext) + " (conflict " + id[:8] + ")" + ext
			old = Asset{}
			exists = false
		}
		if !exists {
			for _, other := range st.Assets {
				if other.Account == a.Account && strings.EqualFold(other.Path, body.Path) {
					conflict = other.ID
					ext := path.Ext(body.Path)
					body.Path = strings.TrimSuffix(body.Path, ext) + " (copy " + id[:8] + ")" + ext
					break
				}
			}
		}
		out = Asset{ID: id, Account: a.Account, Kind: body.Kind, Path: body.Path, MIME: body.MIME, Captured: body.Captured, ConflictOf: conflict, Revisions: append(old.Revisions, Revision{ID: randomID(), SHA256: body.SHA256, Size: body.Size, DeviceID: d.ID, Created: time.Now().Unix()})}
		if exists {
			out.ConflictOf = old.ConflictOf
		}
		st.Assets[id] = out
		head := out.head()
		st.Replicas = append(st.Replicas, Replica{AssetID: id, RevisionID: head.ID, DeviceID: d.ID, Verified: time.Now().Unix()})
		for k, t := range st.Transfers {
			if t.AssetID == id && t.Status != "complete" {
				t.Status = "superseded"
				st.Transfers[k] = t
			}
		}
		plan(st, out)
		return nil
	})
	if err != nil {
		fail(w, 403, "manifest_rejected")
		return
	}
	reply(w, 200, out)
}
func (s *Server) transfers(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	out := []Transfer{}
	for _, t := range s.store.state.Transfers {
		if t.Account == a.Account {
			out = append(out, t)
		}
	}
	reply(w, 200, out)
}
func (s *Server) updateTransfer(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var body struct {
		Status string `json:"status"`
		SHA256 string `json:"sha256"`
	}
	if !decode(w, r, &body) {
		return
	}
	err := s.store.update(func(st *State) error {
		t, exists := st.Transfers[r.PathValue("id")]
		d, e := s.actor(st, a)
		if !exists || t.Account != a.Account || e != nil || (t.From != d.ID && t.To != d.ID) || t.Status == "superseded" {
			return errors.New("forbidden")
		}
		if t.Status == "complete" {
			if body.Status == "complete" && d.ID == t.To {
				return nil
			}
			return errors.New("complete")
		}
		if t.Purpose == "thumbnail" {
			if (body.Status == "complete" && d.ID != t.To) || !slices.Contains([]string{"connecting", "transferring", "waiting_for_peer", "complete", "unavailable"}, body.Status) {
				return errors.New("invalid_thumbnail_status")
			}
		} else if body.Status == "complete" {
			if d.ID != t.To || !d.has("sink") {
				return errors.New("sink_receipt_required")
			}
			asset := st.Assets[t.AssetID]
			var rev Revision
			for _, v := range asset.Revisions {
				if v.ID == t.RevisionID {
					rev = v
				}
			}
			if rev.ID == "" || body.SHA256 != rev.SHA256 {
				return errors.New("hash_mismatch")
			}
			st.Replicas = append(st.Replicas, Replica{AssetID: t.AssetID, RevisionID: t.RevisionID, DeviceID: d.ID, Verified: time.Now().Unix()})
		} else if body.Status != "connecting" && body.Status != "waiting_for_peer" && body.Status != "transferring" {
			return errors.New("invalid_status")
		}
		t.Status = body.Status
		t.Updated = time.Now().Unix()
		st.Transfers[t.ID] = t
		return nil
	})
	if err != nil {
		fail(w, 409, "transfer_update_rejected")
		return
	}
	reply(w, 200, map[string]bool{"ok": true})
}
func (s *Server) signal(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var body struct {
		TransferID string          `json:"transfer_id"`
		Type       string          `json:"type"`
		Data       json.RawMessage `json:"data"`
	}
	if !decode(w, r, &body) {
		return
	}
	if len(body.Data) > 24576 || !slices.Contains([]string{"offer", "answer", "candidate"}, body.Type) || bytes.Contains(body.Data, []byte("typ relay")) {
		fail(w, 400, "invalid_direct_signal")
		return
	}
	s.store.mu.Lock()
	t, exists := s.store.state.Transfers[body.TransferID]
	d, e := s.actor(&s.store.state, a)
	from := s.store.state.Devices[t.From]
	to := s.store.state.Devices[t.To]
	current := s.store.state.Assets[t.AssetID]
	s.store.mu.Unlock()
	if !exists || t.Account != a.Account || e != nil || (t.From != d.ID && t.To != d.ID) || from.Revoked || to.Revoked || (!from.has("source") && !from.has("sink")) || (t.Purpose != "thumbnail" && !to.has("sink")) || (t.Purpose == "thumbnail" && (!to.has("viewer") || current.ID == "" || current.head().ID != t.RevisionID)) || t.Status == "superseded" || t.Status == "complete" || t.Status == "unavailable" || (body.Type == "offer" && t.From != d.ID) || (body.Type == "answer" && t.To != d.ID) {
		fail(w, 403, "signal_forbidden")
		return
	}
	peer := t.To
	if peer == d.ID {
		peer = t.From
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneSignals()
	count := 0
	for _, v := range s.signals {
		if v.TransferID == t.ID {
			count++
		}
	}
	if count >= 256 || len(s.signals) >= 4096 {
		fail(w, 429, "signal_queue_full")
		return
	}
	s.seq++
	s.signals = append(s.signals, Signal{Seq: s.seq, TransferID: t.ID, To: peer, Type: body.Type, Data: body.Data, Created: time.Now().Unix()})
	reply(w, 200, map[string]bool{"ok": true})
}
func (s *Server) pollSignals(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneSignals()
	out := []Signal{}
	for _, v := range s.signals {
		if v.To == a.DeviceID && v.Seq > after {
			out = append(out, v)
		}
	}
	reply(w, 200, map[string]any{"cursor": s.seq, "signals": out})
}
func (s *Server) pruneSignals() {
	kept := s.signals[:0]
	for _, v := range s.signals {
		if v.Created > time.Now().Add(-10*time.Minute).Unix() {
			kept = append(kept, v)
		}
	}
	s.signals = kept
}
