package main

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

type sinkPairing struct {
	id, verifier string
}

func startSinkPairing(t *testing.T, s *Server) sinkPairing {
	t.Helper()
	verifier := randomID() + randomID()
	h := sha256.Sum256([]byte(verifier))
	start := call(t, s, "POST", "/api/auth/native/start", "", map[string]string{
		"challenge": base64.RawURLEncoding.EncodeToString(h[:]), "platform": "linux", "sink_name": "NAS <office>",
	})
	if start.Code != 200 {
		t.Fatal(start.Code, start.Body.String())
	}
	return sinkPairing{value[map[string]string](t, start)["id"], verifier}
}

func (p sinkPairing) browserNonce(t *testing.T, s *Server, browser string) string {
	t.Helper()
	page := call(t, s, "GET", "/native/complete?id="+p.id, browser, nil)
	if page.Code != 200 || !strings.Contains(page.Body.String(), "Allow unattended sink") ||
		!strings.Contains(page.Body.String(), "NAS &lt;office&gt;") {
		t.Fatal(page.Code, page.Body.String())
	}
	match := regexp.MustCompile(`name="approval" value="([a-f0-9]+)"`).FindStringSubmatch(page.Body.String())
	if len(match) != 2 {
		t.Fatal("approval nonce missing")
	}
	return match[1]
}

func (p sinkPairing) approve(s *Server, browser, nonce, deviceID, origin string) *httptest.ResponseRecorder {
	form := url.Values{"id": {p.id}, "approval": {nonce}, "sink_device": {deviceID}}
	req := httptest.NewRequest("POST", "/native/approve", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", origin)
	req.AddCookie(&http.Cookie{Name: s.cookieName(), Value: browser})
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, req)
	return w
}

func (p sinkPairing) poll(t *testing.T, s *Server) *httptest.ResponseRecorder {
	t.Helper()
	return call(t, s, "POST", "/api/auth/native/poll", "", map[string]string{"id": p.id, "verifier": p.verifier})
}

func TestUnattendedSinkPersistsAndCanBeRevoked(t *testing.T) {
	s := fixture(t)
	const account = "account"
	browser, otherDevice := device(t, s, account, "macos", "viewer", "source")
	_, foreignDevice := device(t, s, "other account", "linux", "viewer", "sink")
	legacy, oldSink := device(t, s, account, "linux", "viewer", "sink")
	pair := startSinkPairing(t, s)
	if got := pair.poll(t, s); got.Code != 202 {
		t.Fatal("approval was bypassed", got.Code)
	}
	nonce := pair.browserNonce(t, s, browser)
	for _, tc := range []struct {
		device, origin string
		code           int
	}{
		{oldSink.ID, "https://untrusted.example", 403},
		{foreignDevice.ID, s.appURL, 409},
		{otherDevice.ID, s.appURL, 409},
		{oldSink.ID, s.appURL, 200},
	} {
		if got := pair.approve(s, browser, nonce, tc.device, tc.origin); got.Code != tc.code {
			t.Fatalf("approval returned %d, want %d: %s", got.Code, tc.code, got.Body)
		}
	}
	if got := pair.approve(s, browser, nonce, oldSink.ID, s.appURL); got.Code != 403 {
		t.Fatal("replayed browser approval accepted", got.Code)
	}
	wrong := sinkPairing{pair.id, "wrong verifier"}
	if got := wrong.poll(t, s); got.Code != 404 {
		t.Fatal("wrong verifier accepted", got.Code)
	}
	token := value[map[string]string](t, pair.poll(t, s))["token"]
	if !strings.HasPrefix(token, sinkTokenPrefix) || token != value[map[string]string](t, pair.poll(t, s))["token"] {
		t.Fatal("poll did not issue a repeatable sink credential")
	}
	if got := call(t, s, "GET", "/api/me", legacy, nil); got.Code != 401 {
		t.Fatal("legacy credential still active", got.Code)
	}
	raw, err := os.ReadFile(s.store.file)
	if err != nil || strings.Contains(string(raw), token) {
		t.Fatal("catalog must store only the sink credential hash", err)
	}
	if err := s.store.update(func(st *State) error {
		expired := st.Sessions[tokenHash(browser)]
		expired.Expires = time.Now().Add(-8 * time.Hour).Unix()
		st.Sessions[tokenHash(browser)] = expired
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	reloaded, err := openStore(s.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	s.store = reloaded
	s.pending = map[string]pendingLogin{}
	if w := call(t, s, "GET", "/api/me", browser, nil); w.Code != 401 {
		t.Fatal("browser expiry changed", w.Code)
	}
	s.dev = false // No IAM configured. The sink does not borrow a browser session.
	got := call(t, s, "GET", "/api/me", token, nil)
	me := value[map[string]any](t, got)
	if got.Code != 200 || me["device_id"] != oldSink.ID || me["unattended_sink"] != true {
		t.Fatal("sink credential did not survive expiration and restart", got.Code, me)
	}
	s.dev = true
	freshBrowser, _ := device(t, s, account, "macos", "viewer")
	current := startSinkPairing(t, s)
	delayed := startSinkPairing(t, s)
	for _, p := range []sinkPairing{current, delayed} {
		if got := p.approve(s, freshBrowser, p.browserNonce(t, s, freshBrowser), oldSink.ID, s.appURL); got.Code != 200 {
			t.Fatal(got.Code, got.Body.String())
		}
	}
	newToken := value[map[string]string](t, current.poll(t, s))["token"]
	if newToken == "" || newToken == token {
		t.Fatal("rotation did not replace the sink credential")
	}
	if got := delayed.poll(t, s); got.Code != 409 {
		t.Fatal("stale approval replaced the new credential", got.Code)
	}
	if got := call(t, s, "GET", "/api/me", token, nil); got.Code != 401 {
		t.Fatal("rotated credential still active", got.Code)
	}
	if got := call(t, s, "DELETE", "/api/devices/"+oldSink.ID, freshBrowser, nil); got.Code != 200 {
		t.Fatal(got.Code, got.Body.String())
	}
	if got := call(t, s, "GET", "/api/me", newToken, nil); got.Code != 401 {
		t.Fatal("revoked credential still active", got.Code)
	}
	if len(s.store.state.SinkCredentials) != 0 {
		t.Fatal("revocation left a credential hash in the catalog")
	}
}

func TestUnattendedSinkOnlyHandlesItsAssignedTransfers(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "account", "macos", "viewer", "source")
	pair := startSinkPairing(t, s)
	if got := pair.approve(s, source, pair.browserNonce(t, s, source), "", s.appURL); got.Code != 200 {
		t.Fatal(got.Code, got.Body.String())
	}
	token := value[map[string]string](t, pair.poll(t, s))["token"]
	me := value[map[string]any](t, call(t, s, "GET", "/api/me", token, nil))
	id := me["device_id"].(string)
	cookieReq := httptest.NewRequest("GET", "/api/me", nil)
	cookieReq.AddCookie(&http.Cookie{Name: s.cookieName(), Value: token})
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, cookieReq)
	if w.Code != 401 {
		t.Fatal("bearer was accepted as a cookie", w.Code)
	}
	for _, req := range []struct{ method, route string }{
		{"POST", "/api/assets"}, {"POST", "/api/devices"}, {"DELETE", "/api/devices/" + id},
		{"POST", "/api/thumbnail-requests"}, {"GET", "/native/complete?id=" + pair.id},
	} {
		if got := call(t, s, req.method, req.route, token, nil); got.Code != 403 {
			t.Fatalf("%s %s returned %d: %s", req.method, req.route, got.Code, got.Body)
		}
	}
	ownDevices := value[[]Device](t, call(t, s, "GET", "/api/devices", token, nil))
	if len(ownDevices) != 1 || ownDevices[0].ID != id {
		t.Fatal("sink received other devices")
	}
	hash := strings.Repeat("a", 64)
	pub := call(t, s, "POST", "/api/assets", source, map[string]any{
		"kind": "file", "path": "Files/library.photoslibrary.tar.gz", "mime": "application/gzip", "sha256": hash, "size": 40,
	})
	if pub.Code != 200 {
		t.Fatal(pub.Code, pub.Body.String())
	}
	asset := value[Asset](t, pub)
	_, otherSink := device(t, s, "account", "windows", "viewer", "sink")
	assigned := value[[]Transfer](t, call(t, s, "GET", "/api/transfers", token, nil))
	if len(assigned) != 1 || assigned[0].To != id || assigned[0].AssetID != asset.ID {
		t.Fatalf("wrong assigned transfers: %+v", assigned)
	}
	all := value[[]Transfer](t, call(t, s, "GET", "/api/transfers", source, nil))
	for _, job := range all {
		if job.To == otherSink.ID {
			if got := call(t, s, "POST", "/api/transfers/"+job.ID, token, map[string]string{"status": "complete", "sha256": hash}); got.Code != 409 {
				t.Fatal("sink updated another device's transfer", got.Code)
			}
		}
	}
	type manifest struct{ Asset Asset }
	assets := value[[]manifest](t, call(t, s, "GET", "/api/assets", token, nil))
	if len(assets) != 1 || assets[0].Asset.ID != asset.ID {
		t.Fatal("sink did not receive the assigned manifest")
	}
	if got := call(t, s, "POST", "/api/transfers/"+assigned[0].ID, token, map[string]string{"status": "complete", "sha256": hash}); got.Code != 200 {
		t.Fatal("sink could not acknowledge its receipt", got.Code, got.Body.String())
	}
	if after := value[[]manifest](t, call(t, s, "GET", "/api/assets", token, nil)); len(after) != 0 {
		t.Fatal("sink received a manifest without active work")
	}
}
