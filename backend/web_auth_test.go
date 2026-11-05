package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jeethsuresh/haven/backend/internal/gravitas"
)

func TestWebLoginCookieSessionAndRecovery(t *testing.T) {
	s := fixture(t)
	s.dev = false
	app := httptest.NewTLSServer(s.handler())
	defer app.Close()
	s.appURL = app.URL
	var issuer string
	var revoked atomic.Bool
	expires := time.Now().Add(time.Hour).Unix()
	check := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	family := "11111111-1111-4111-8111-111111111111"
	iam := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/iam-configuration":
			u, _ := url.Parse(issuer)
			reply(w, 200, map[string]string{"issuer": issuer, "identity_domain": u.Hostname(), "browser_initiation_endpoint": issuer + "/oauth/start", "token_endpoint": issuer + "/oauth/token", "userinfo_endpoint": issuer + "/app/v1/me", "session_check_endpoint": issuer + "/oauth/session"})
		case "/oauth/start":
			q := r.URL.Query()
			if q.Get("scope") != "profile.name" || q.Get("codeChallengeMethod") != "S256" {
				t.Error("incorrect web permissions/proof")
			}
			http.Redirect(w, r, q.Get("redirectURL")+"?code=web-code&state="+url.QueryEscape(q.Get("state")), 303)
		case "/oauth/token":
			r.ParseForm()
			if r.Form.Get("code") != "web-code" || r.Form.Get("redirect_uri") != app.URL+"/auth/gravitas/callback" || len(r.Form.Get("code_verifier")) != 43 {
				t.Error("incorrect web code exchange")
			}
			reply(w, 200, map[string]any{"access_token": "private-access", "token_type": "Bearer", "session_check_token": check, "session_check_expires_in": expires - time.Now().Unix(), "session_id": family})
		case "/app/v1/me":
			u, _ := url.Parse(issuer)
			// The current IAM intentionally omits username/user_id without that scope.
			reply(w, 200, map[string]string{"sub": "alice", "domain": u.Hostname(), "name": "Alice"})
		case "/oauth/session":
			if revoked.Load() {
				w.WriteHeader(401)
				return
			}
			reply(w, 200, map[string]any{"active": true, "iss": issuer, "sub": "alice", "app_origin": app.URL, "session_id": family, "exp": expires})
		default:
			w.WriteHeader(404)
		}
	}))
	defer iam.Close()
	issuer = iam.URL
	var err error
	s.iam, err = gravitas.New(issuer, app.URL, base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	s.iam.HTTP.Transport = iam.Client().Transport
	browser := app.Client()
	browser.Jar, _ = cookiejar.New(nil)
	get := func(path string) (*http.Response, string) {
		t.Helper()
		response, err := browser.Get(app.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		content, _ := io.ReadAll(response.Body)
		response.Body.Close()
		return response, string(content)
	}
	_, page := get("/login?next=%2F%23library&reason=%3Cscript%3E")
	if !strings.Contains(page, "Continue with Gravitas") || strings.Contains(page, "<script>") {
		t.Fatal("unusable sign-in page", page)
	}
	response, _ := get("/auth/gravitas/start?next=%2F%23library")
	if response.StatusCode != 200 || response.Request.URL.Fragment != "library" {
		t.Fatal("web login lost return destination", response.Request.URL)
	}
	appURL, _ := url.Parse(app.URL)
	var session *http.Cookie
	for _, cookie := range browser.Jar.Cookies(appURL) {
		if cookie.Name == "__Host-haven" {
			session = cookie
		}
	}
	if session == nil {
		t.Fatal("web login did not save host session")
	}
	response, body := get("/api/me")
	if response.StatusCode != 200 || strings.Contains(body, check) || strings.Contains(body, "private-access") {
		t.Fatal("web session unusable or leaked credentials", body)
	}
	req, _ := http.NewRequest("POST", app.URL+"/api/devices", strings.NewReader(`{"name":"Web viewer","platform":"web","roles":["viewer"]}`))
	req.Header.Set("Origin", app.URL)
	req.Header.Set("X-Haven-CSRF", "1")
	req.Header.Set("Content-Type", "application/json")
	response, err = browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var device Device
	json.NewDecoder(response.Body).Decode(&device)
	response.Body.Close()
	if response.StatusCode != 200 || device.ID == "" || s.store.state.Devices[device.ID].Account != accountKey(issuer, "alice") {
		t.Fatal("cookie-backed web viewer registration failed", response.StatusCode)
	}
	response, body = get("/api/me")
	if response.StatusCode != 200 || !strings.Contains(body, device.ID) {
		t.Fatal("web session lost device registration")
	}
	response, _ = get("/api/assets")
	if response.StatusCode != 200 {
		t.Fatal("web library unavailable")
	}
	// Missing state/cookie errors return a real, retryable page, not raw JSON.
	response, body = get("/auth/gravitas/callback?code=private-code&state=wrong")
	if response.StatusCode != 200 || response.Request.URL.Path != "/login" || !strings.Contains(body, "expired or was cancelled") || strings.Contains(body, "private-code") {
		t.Fatal("callback recovery failed", response.Request.URL, body)
	}
	response, body = get("/login?next=https%3A%2F%2Fevil.example&reason=expired")
	if response.StatusCode != 200 || strings.Contains(body, "evil.example") {
		t.Fatal("unsafe recovery redirect")
	}
	revoked.Store(true)
	response, _ = get("/api/me")
	if response.StatusCode != 401 {
		t.Fatal("revoked website session accepted")
	}
}

func TestLoginRecoveryWhenIdentityUnavailable(t *testing.T) {
	s := fixture(t)
	for _, path := range []string{"/auth/gravitas/start?next=%2Fnative%2Fcomplete%3Fid%3Dpending", "/auth/gravitas/callback?code=secret"} {
		w := call(t, s, "GET", path, "", nil)
		target, err := url.Parse(w.Header().Get("Location"))
		if err != nil || w.Code != 303 || target.Path != "/login" || target.Query().Get("reason") != "unavailable" || strings.Contains(target.String(), "secret") {
			t.Fatal("identity outage was not recoverable", w.Code, w.Header())
		}
	}
}
