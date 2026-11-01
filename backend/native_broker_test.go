package main

import (
	"encoding/base64"
	"github.com/jeethsuresh/haven/backend/internal/gravitas"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDesktopBrokerSessionExchangeReplayAndRevocation(t *testing.T) {
	s := fixture(t)
	s.dev = false
	s.appURL = "https://haven.example"
	var issuer string
	expires := time.Now().Add(time.Hour).Unix()
	check := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	family := "11111111-1111-4111-8111-111111111111"
	var used, revoked atomic.Bool
	iam := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/iam-configuration":
			u, _ := url.Parse(issuer)
			reply(w, 200, map[string]string{"issuer": issuer, "identity_domain": u.Hostname(), "browser_initiation_endpoint": issuer + "/oauth/start", "token_endpoint": issuer + "/oauth/token", "userinfo_endpoint": issuer + "/app/v1/me", "session_check_endpoint": issuer + "/oauth/session"})
		case "/oauth/token":
			r.ParseForm()
			if used.Load() || r.Form.Get("code") != strings.Repeat("c", 43) || r.Form.Get("code_verifier") != strings.Repeat("v", 43) || r.Form.Get("redirect_uri") != s.appURL+"/auth/gravitas/callback" {
				w.WriteHeader(400)
				return
			}
			used.Store(true)
			reply(w, 200, map[string]any{"access_token": "private", "token_type": "Bearer", "session_check_token": check, "session_check_expires_in": expires - time.Now().Unix(), "session_id": family})
		case "/app/v1/me":
			u, _ := url.Parse(issuer)
			reply(w, 200, map[string]string{"sub": "alice", "username": "alice", "domain": u.Hostname(), "user_id": "@alice:" + u.Hostname()})
		case "/oauth/session":
			if revoked.Load() {
				w.WriteHeader(401)
				return
			}
			reply(w, 200, map[string]any{"active": true, "iss": issuer, "sub": "alice", "app_origin": s.appURL, "session_id": family, "exp": expires})
		default:
			t.Error("unexpected IAM request")
			w.WriteHeader(404)
		}
	}))
	defer iam.Close()
	issuer = iam.URL
	var err error
	s.iam, err = gravitas.New(issuer, s.appURL, base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	s.iam.HTTP.Transport = iam.Client().Transport
	body := map[string]string{"code": strings.Repeat("c", 43), "code_verifier": strings.Repeat("v", 43), "sub": "alice", "session_id": family}
	// The narrow native endpoint still enforces exact-origin/CSRF policy.
	invalid := httptest.NewRequest("POST", "/api/auth/native/broker", strings.NewReader(`{}`))
	invalid.Header.Set("X-Haven-CSRF", "1")
	invalid.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, invalid)
	if w.Code != 403 || used.Load() {
		t.Fatal("cross-origin broker exchange accepted")
	}
	w = call(t, s, "POST", "/api/auth/native/broker", "", body)
	if w.Code != 200 || len(w.Result().Cookies()) != 0 {
		t.Fatal("native exchange failed", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), check) || strings.Contains(w.Body.String(), "private") {
		t.Fatal("IAM credential exposed")
	}
	token := value[map[string]string](t, w)["token"]
	if w = call(t, s, "GET", "/api/me", token, nil); w.Code != 200 {
		t.Fatal("broker session unusable", w.Code)
	}
	if w = call(t, s, "POST", "/api/auth/native/broker", "", body); w.Code != 401 {
		t.Fatal("code replay accepted", w.Code)
	}
	revoked.Store(true)
	if w = call(t, s, "GET", "/api/me", token, nil); w.Code != 401 {
		t.Fatal("revoked family accepted", w.Code)
	}
}
