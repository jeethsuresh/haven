package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jeethsuresh/haven/backend/internal/gravitas"
)

// Exercise the native client and external browser as separate cookie contexts.
func TestNativeLoginBrowserApprovalAndAndroidSession(t *testing.T) {
	s := fixture(t)
	s.dev = false
	app := httptest.NewTLSServer(s.handler())
	defer app.Close()
	s.appURL = app.URL
	var issuer string
	expiry := time.Now().Add(time.Hour).Unix()
	check := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/iam-configuration", func(w http.ResponseWriter, r *http.Request) {
		origin, _ := url.Parse(issuer)
		reply(w, 200, map[string]string{"issuer": issuer, "identity_domain": origin.Hostname(), "browser_initiation_endpoint": issuer + "/oauth/start", "token_endpoint": issuer + "/oauth/token", "userinfo_endpoint": issuer + "/app/v1/me", "session_check_endpoint": issuer + "/oauth/session"})
	})
	mux.HandleFunc("GET /oauth/start", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("callerURL") != app.URL || q.Get("codeChallengeMethod") != "S256" {
			t.Error("incorrect IAM handoff")
		}
		http.Redirect(w, r, q.Get("redirectURL")+"?code=test-code&state="+url.QueryEscape(q.Get("state")), 303)
	})
	mux.HandleFunc("POST /oauth/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Form.Get("code") != "test-code" || r.Form.Get("redirect_uri") != app.URL+"/auth/gravitas/callback" {
			t.Error("invalid token exchange")
		}
		reply(w, 200, map[string]any{"access_token": "test-access", "token_type": "Bearer", "session_check_token": check, "session_check_expires_in": expiry - time.Now().Unix(), "session_id": "11111111-1111-4111-8111-111111111111"})
	})
	mux.HandleFunc("GET /app/v1/me", func(w http.ResponseWriter, r *http.Request) {
		origin, _ := url.Parse(issuer)
		reply(w, 200, map[string]string{"issuer": issuer, "sub": "alice", "username": "alice", "domain": origin.Hostname(), "user_id": "@alice:" + origin.Hostname()})
	})
	mux.HandleFunc("GET /oauth/session", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+check {
			t.Error("status proof missing")
		}
		reply(w, 200, map[string]any{"active": true, "iss": issuer, "sub": "alice", "app_origin": app.URL, "session_id": "11111111-1111-4111-8111-111111111111", "exp": expiry})
	})
	iam := httptest.NewTLSServer(mux)
	defer iam.Close()
	issuer = iam.URL
	var err error
	s.iam, err = gravitas.New(issuer, app.URL, base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	s.iam.HTTP.Transport = iam.Client().Transport
	verifier := strings.Repeat("v", 43)
	hash := sha256.Sum256([]byte(verifier))
	started := call(t, s, "POST", "/api/auth/native/start", "", map[string]string{"challenge": base64.RawURLEncoding.EncodeToString(hash[:]), "platform": "android"})
	if started.Code != 200 {
		t.Fatal(started.Body.String())
	}
	start := value[map[string]string](t, started)
	poll := func(v string) *httptest.ResponseRecorder {
		return call(t, s, "POST", "/api/auth/native/poll", "", map[string]string{"id": start["id"], "verifier": v})
	}
	if w := poll(verifier); w.Code != 202 {
		t.Fatal("poll before approval", w.Code, w.Body.String())
	}
	browser := app.Client()
	browser.Jar, _ = cookiejar.New(nil)
	page, err := browser.Get(start["approval_url"])
	if err != nil {
		t.Fatal(err)
	}
	content, _ := io.ReadAll(page.Body)
	page.Body.Close()
	if page.StatusCode != 200 || !strings.Contains(page.Request.URL.Path, "/native/complete") {
		t.Fatalf("browser handoff failed: %d %s %s", page.StatusCode, page.Request.URL, content)
	}
	match := regexp.MustCompile(`name="approval" value="([a-f0-9]+)"`).FindSubmatch(content)
	if len(match) != 2 {
		t.Fatalf("approval form missing: %s", content)
	}
	if w := poll(verifier); w.Code != 202 {
		t.Fatal("browser login alone bypassed approval")
	}
	form := url.Values{"id": {start["id"]}, "approval": {string(match[1])}}
	req, _ := http.NewRequest("POST", app.URL+"/native/approve", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", app.URL)
	approved, err := browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer approved.Body.Close()
	body, _ := io.ReadAll(approved.Body)
	if !strings.Contains(string(body), "intent://auth/complete#Intent;scheme=haven;package=cool.gravitas.haven;end") {
		t.Fatal("Android return link missing")
	}
	if strings.Contains(string(body), verifier) || strings.Contains(string(body), check) {
		t.Fatal("credentials leaked in browser success page")
	}
	if approved.StatusCode != 200 {
		body, _ := io.ReadAll(approved.Body)
		t.Fatalf("approval failed %d %s", approved.StatusCode, body)
	}
	// Android Back or tab restore can revisit the approval URL before the app's
	// paused poller resumes. That navigation must not undo completed approval.
	revisited, err := browser.Get(app.URL + "/native/complete?id=" + start["id"])
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, revisited.Body)
	revisited.Body.Close()
	if w := poll(strings.Repeat("wrong", 9)); w.Code != 404 {
		t.Fatal("wrong verifier redeemed approval")
	}
	redeemed := poll(verifier)
	if redeemed.Code != 200 {
		t.Fatal(redeemed.Code, redeemed.Body.String())
	}
	token := value[map[string]string](t, redeemed)["token"]
	if token == "" {
		t.Fatal("native token missing")
	}
	if w := call(t, s, "GET", "/api/me", token, nil); w.Code != 200 {
		t.Fatal("native session unusable", w.Code, w.Body.String())
	}
	registered := call(t, s, "POST", "/api/devices", token, map[string]any{"name": "Android phone", "platform": "android", "roles": []string{"viewer"}})
	if registered.Code != 200 {
		t.Fatal("native device registration failed", registered.Code, registered.Body.String())
	}
	var device Device
	json.Unmarshal(registered.Body.Bytes(), &device)
	if device.ID == "" || device.Platform != "android" {
		t.Fatal("Android device not registered")
	}
	if w := poll(verifier); w.Code != 404 {
		t.Fatal("native approval replayed")
	}
}

func TestNativeLoginOldClientsDoNotReceiveAnUnsupportedAppLink(t *testing.T) {
	s := fixture(t)
	token, _ := s.issueSession("alice", "", time.Now().Add(time.Hour).Unix())
	verifier := strings.Repeat("v", 43)
	digest := sha256.Sum256([]byte(verifier))
	start := value[map[string]string](t, call(t, s, "POST", "/api/auth/native/start", "", map[string]string{"challenge": base64.RawURLEncoding.EncodeToString(digest[:])}))
	page := call(t, s, "GET", "/native/complete?id="+start["id"], token, nil)
	if page.Code != 200 {
		t.Fatal(page.Body.String())
	}
	s.mu.Lock()
	p := s.pending[start["id"]]
	p.Approval = "approved"
	s.pending[start["id"]] = p
	s.mu.Unlock()
	revisited := call(t, s, "GET", "/native/complete?id="+start["id"], token, nil)
	if revisited.Code != 200 || !strings.Contains(revisited.Body.String(), "You're connected") || strings.Contains(revisited.Body.String(), "intent:") {
		t.Fatal("old-client browser navigation regressed", revisited.Body.String())
	}
	other, _ := s.issueSession("bob", "", time.Now().Add(time.Hour).Unix())
	if w := call(t, s, "GET", "/native/complete?id="+start["id"], other, nil); w.Code != 403 {
		t.Fatal("approved login rebound to another account")
	}
	if w := call(t, s, "POST", "/api/auth/native/poll", "", map[string]string{"id": start["id"], "verifier": verifier}); w.Code != 200 {
		t.Fatal("approved legacy login was lost", w.Body.String())
	}
}
