package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) *Server {
	t.Helper()
	dir := t.TempDir()
	st, e := openStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	return &Server{store: st, dev: true, appURL: "http://127.0.0.1:8090", dataDir: dir, webDir: t.TempDir(), stunURLs: []string{}, pending: map[string]pendingLogin{}}
}
func call(t *testing.T, s *Server, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var b []byte
	switch v := body.(type) {
	case []byte:
		b = v
	case string:
		b = []byte(v)
	default:
		if body != nil {
			b, _ = json.Marshal(body)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	r.Header.Set("X-Haven-CSRF", "1")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, r)
	return w
}
func value[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var out T
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON %s: %v", w.Body.String(), err)
	}
	return out
}
func device(t *testing.T, s *Server, account, platform string, roles ...string) (string, Device) {
	t.Helper()
	token, e := s.issueSession(account, "", time.Now().Add(time.Hour).Unix())
	if e != nil {
		t.Fatal(e)
	}
	w := call(t, s, "POST", "/api/devices", token, map[string]any{"name": platform, "platform": platform, "roles": roles})
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	return token, value[Device](t, w)
}
func manifest() map[string]any {
	return map[string]any{"kind": "media", "path": "Media/2026/10/photo.jpg", "mime": "image/jpeg", "sha256": strings.Repeat("a", 64), "size": 1234, "captured": int64(1793100000)}
}
func publishAsset(t *testing.T, s *Server, token string, body map[string]any) Asset {
	t.Helper()
	w := call(t, s, "POST", "/api/assets", token, body)
	if w.Code != 200 {
		t.Fatalf("publish: %d %s", w.Code, w.Body.String())
	}
	return value[Asset](t, w)
}
func TestMediaLifecycleRequiresVerifiedSinkReceipt(t *testing.T) {
	s := fixture(t)
	source, phone := device(t, s, "alice", "android", "viewer", "source")
	sink, desktop := device(t, s, "alice", "linux", "viewer", "sink")
	asset := publishAsset(t, s, source, manifest())
	jobs := value[[]Transfer](t, call(t, s, "GET", "/api/transfers", source, nil))
	if len(jobs) != 1 || jobs[0].From != phone.ID || jobs[0].To != desktop.ID {
		t.Fatalf("incorrect plan: %+v", jobs)
	}
	getCopies := func() int {
		return int(value[[]map[string]any](t, call(t, s, "GET", "/api/assets", source, nil))[0]["sink_copies"].(float64))
	}
	if getCopies() != 0 {
		t.Fatal("source advertisement falsely counted as backup")
	}
	job := jobs[0]
	for _, test := range []struct{ token, hash string }{{source, asset.head().SHA256}, {sink, strings.Repeat("b", 64)}} {
		w := call(t, s, "POST", "/api/transfers/"+job.ID, test.token, map[string]string{"status": "complete", "sha256": test.hash})
		if w.Code != 409 {
			t.Fatalf("invalid receipt accepted: %d", w.Code)
		}
	}
	if getCopies() != 0 {
		t.Fatal("invalid receipt changed replicas")
	}
	w := call(t, s, "POST", "/api/transfers/"+job.ID, sink, map[string]string{"status": "complete", "sha256": asset.head().SHA256})
	if w.Code != 200 || getCopies() != 1 {
		t.Fatalf("verified receipt failed: %s", w.Body.String())
	}
	// A repeated receipt is idempotent, never an extra backup copy.
	call(t, s, "POST", "/api/transfers/"+job.ID, sink, map[string]string{"status": "complete", "sha256": asset.head().SHA256})
	if getCopies() != 1 {
		t.Fatal("duplicate receipt counted twice")
	}
	if w = call(t, s, "POST", "/api/transfers/"+job.ID, source, map[string]string{"status": "waiting_for_peer"}); w.Code != 409 {
		t.Fatal("completed transfer regressed")
	}
}
func TestIsolationRolesAndNoOriginalUpload(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "alice", "android", "viewer", "source")
	viewer, _ := device(t, s, "alice", "web", "viewer")
	stranger, _ := device(t, s, "bob", "linux", "viewer", "sink")
	asset := publishAsset(t, s, source, manifest())
	if len(value[[]any](t, call(t, s, "GET", "/api/assets", stranger, nil))) != 0 {
		t.Fatal("cross-account asset leak")
	}
	if w := call(t, s, "POST", "/api/assets", viewer, manifest()); w.Code != 403 {
		t.Fatal("viewer published an original manifest")
	}
	if w := call(t, s, "GET", "/api/assets/"+asset.ID+"/thumbnail", stranger, nil); w.Code != 404 {
		t.Fatal("cross-account thumbnail leak")
	}
	if w := call(t, s, "POST", "/api/assets", source, `{"kind":"media","original":"base64"}`); w.Code != 400 {
		t.Fatal("unknown upload field accepted")
	}
	if w := call(t, s, "POST", "/api/assets/"+asset.ID+"/original", source, strings.Repeat("x", 1024)); w.Code != 404 {
		t.Fatal("backend accepted original bytes")
	}
	w := call(t, s, "POST", "/api/devices", viewer, map[string]any{"name": "web sink", "platform": "web", "roles": []string{"viewer", "sink"}})
	if w.Code != 400 {
		t.Fatal("web sink allowed")
	}
}
func TestConcurrentEditsPreserveBothBranches(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "alice", "android", "viewer", "source")
	sink, _ := device(t, s, "alice", "linux", "viewer", "sink")
	first := publishAsset(t, s, source, manifest())
	edit := manifest()
	edit["id"] = first.ID
	edit["base"] = first.head().ID
	edit["sha256"] = strings.Repeat("b", 64)
	second := publishAsset(t, s, sink, edit)
	edit["sha256"] = strings.Repeat("c", 64)
	conflict := publishAsset(t, s, source, edit)
	if conflict.ID == first.ID || conflict.ConflictOf != first.ID || conflict.Path == first.Path {
		t.Fatalf("concurrent edit not preserved: %+v", conflict)
	}
	if len(second.Revisions) != 2 || len(conflict.Revisions) != 1 {
		t.Fatal("revision history lost")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if s.store.state.Assets[first.ID].head().SHA256 != strings.Repeat("b", 64) {
		t.Fatal("canonical head silently overwritten")
	}
}
func TestValidationAndNoServerThumbnailBytes(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "alice", "android", "viewer", "source")
	for _, p := range []string{"Media/../escape", "/Media/photo.jpg", "Media/a\\b.jpg", "Media/CON.jpg", "Media/a:stream", "Media/a/./b", "Files/a.jpg", "Media/a\x00.jpg"} {
		m := manifest()
		m["path"] = p
		if w := call(t, s, "POST", "/api/assets", source, m); w.Code != 400 {
			t.Fatalf("unsafe path accepted: %q", p)
		}
	}
	a := publishAsset(t, s, source, manifest())
	url := "/api/assets/" + a.ID + "/thumbnail"
	for _, method := range []string{"PUT", "GET"} {
		if w := call(t, s, method, url, source, bytes.Repeat([]byte("thumbnail"), 1024)); w.Code != 404 {
			t.Fatalf("backend accepted or served thumbnail bytes: %d", w.Code)
		}
	}
}
func TestSignalsAreAccountAndTransferBound(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "alice", "android", "viewer", "source")
	sink, _ := device(t, s, "alice", "linux", "viewer", "sink")
	other, _ := device(t, s, "alice", "linux", "viewer")
	stranger, _ := device(t, s, "bob", "linux", "viewer", "sink")
	publishAsset(t, s, source, manifest())
	jobs := value[[]Transfer](t, call(t, s, "GET", "/api/transfers", source, nil))
	body := map[string]any{"transfer_id": jobs[0].ID, "type": "offer", "data": map[string]string{"sdp": "v=0\r\nm=application"}}
	for _, token := range []string{sink, other, stranger} {
		if w := call(t, s, "POST", "/api/signals", token, body); w.Code != 403 {
			t.Fatal("unauthorized signal accepted")
		}
	}
	if w := call(t, s, "POST", "/api/signals", source, body); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	read := value[struct {
		Cursor  int64    `json:"cursor"`
		Signals []Signal `json:"signals"`
	}](t, call(t, s, "GET", "/api/signals?after=0", sink, nil))
	if len(read.Signals) != 1 {
		t.Fatal("signal not delivered")
	}
	if len(value[struct {
		Signals []Signal `json:"signals"`
	}](t, call(t, s, "GET", "/api/signals", other, nil)).Signals) != 0 {
		t.Fatal("signal leaked to another device")
	}
	body["type"] = "candidate"
	body["data"] = map[string]string{"candidate": "candidate:x typ relay"}
	if w := call(t, s, "POST", "/api/signals", source, body); w.Code != 400 {
		t.Fatal("TURN relay candidate accepted")
	}
}
func TestSnapshotsRetainOwnershipAndFailedUpdateRollsBack(t *testing.T) {
	s := fixture(t)
	source, d := device(t, s, "alice", "android", "viewer", "source")
	a := publishAsset(t, s, source, manifest())
	reopened, e := openStore(s.dataDir)
	if e != nil {
		t.Fatal(e)
	}
	if reopened.state.Devices[d.ID].Account != "alice" || reopened.state.Assets[a.ID].Account != "alice" {
		t.Fatal("ownership lost after restart")
	}
	original := s.store.file
	s.store.file = filepath.Join(s.dataDir, "missing", "catalog.json")
	e = s.store.update(func(st *State) error { delete(st.Assets, a.ID); return nil })
	if e == nil {
		t.Fatal("write unexpectedly succeeded")
	}
	if _, ok := s.store.state.Assets[a.ID]; !ok {
		t.Fatal("failed write changed in-memory state")
	}
	s.store.file = original
	info, e := os.Stat(original)
	if e != nil || info.Mode().Perm()&0077 != 0 {
		t.Fatal("catalog permissions not private")
	}
}
func TestRevokedDeviceCannotReadOrSignal(t *testing.T) {
	s := fixture(t)
	source, d := device(t, s, "alice", "android", "viewer", "source")
	viewer, _ := device(t, s, "alice", "web", "viewer")
	call(t, s, "DELETE", "/api/devices/"+d.ID, viewer, nil)
	if w := call(t, s, "GET", "/api/assets", source, nil); w.Code != 401 {
		t.Fatal("revoked device retains access")
	}
}
func TestCSRFAndCookieIsolation(t *testing.T) {
	s := fixture(t)
	token, _ := device(t, s, "alice", "web", "viewer")
	r := httptest.NewRequest("POST", "/api/devices/heartbeat", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("missing csrf marker accepted")
	}
	r = httptest.NewRequest("POST", "/api/dev/login", nil)
	r.Header.Set("X-Haven-CSRF", "1")
	r.Header.Set("Origin", "https://evil.example")
	w = httptest.NewRecorder()
	s.handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("foreign origin accepted")
	}
}
