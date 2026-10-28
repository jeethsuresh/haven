package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/jeethsuresh/haven/backend/internal/gravitas"
)

type pendingLogin struct {
	Challenge, Envelope, Account, Approval string
	Platform                               string
	Expires                                int64
}

func (s *Server) cookieName() string {
	if s.dev {
		return "haven_dev"
	}
	return "__Host-haven"
}
func (s *Server) setCookie(w http.ResponseWriter, token string, seconds int) {
	http.SetCookie(w, &http.Cookie{Name: s.cookieName(), Value: token, Path: "/", HttpOnly: true, Secure: !s.dev, SameSite: http.SameSiteLaxMode, MaxAge: seconds})
}
func (s *Server) rawToken(r *http.Request) string {
	if v := r.Header.Get("Authorization"); strings.HasPrefix(v, "Bearer ") {
		return strings.TrimPrefix(v, "Bearer ")
	}
	if c, e := r.Cookie(s.cookieName()); e == nil {
		return c.Value
	}
	return ""
}
func (s *Server) authorize(w http.ResponseWriter, r *http.Request) (Session, string, bool) {
	token := s.rawToken(r)
	key := tokenHash(token)
	s.store.mu.Lock()
	session, ok := s.store.state.Sessions[key]
	device := s.store.state.Devices[session.DeviceID]
	s.store.mu.Unlock()
	if !ok || session.Expires <= time.Now().Unix() || (session.DeviceID != "" && device.Revoked) {
		fail(w, 401, "sign_in_required")
		return Session{}, "", false
	}
	if !s.dev {
		// Check the central family before every protected operation. An outage
		// denies access but retains the session and all local pending work.
		_, err := s.iam.AuthenticateValue(r.Context(), session.Envelope)
		if err != nil {
			if errors.Is(err, gravitas.ErrUnavailable) {
				fail(w, 503, "identity_unavailable")
			} else {
				fail(w, 401, "sign_in_required")
			}
			return Session{}, "", false
		}
	}
	if r.Method != "GET" && r.Method != "HEAD" && !s.validMutation(r) {
		fail(w, 403, "invalid_origin_or_csrf")
		return Session{}, "", false
	}
	return session, key, true
}
func (s *Server) validMutation(r *http.Request) bool {
	return r.Header.Get("X-Haven-CSRF") == "1" && (r.Header.Get("Origin") == "" || r.Header.Get("Origin") == s.appURL)
}
func (s *Server) issueSession(account, envelope string, expires int64) (string, error) {
	token := randomID() + randomID()
	err := s.store.update(func(st *State) error {
		for k, v := range st.Sessions {
			if v.Expires < time.Now().Unix() {
				delete(st.Sessions, k)
			}
		}
		st.Sessions[tokenHash(token)] = Session{Account: account, Envelope: envelope, Expires: expires}
		return nil
	})
	return token, err
}
func (s *Server) authRoutes(m *http.ServeMux) {
	m.HandleFunc("POST /api/dev/login", func(w http.ResponseWriter, r *http.Request) {
		if !s.dev {
			fail(w, 404, "not_found")
			return
		}
		if !s.validMutation(r) {
			fail(w, 403, "invalid_origin_or_csrf")
			return
		}
		token, err := s.issueSession(accountKey("local", "developer"), "", time.Now().Add(24*time.Hour).Unix())
		if err != nil {
			fail(w, 500, "storage_failed")
			return
		}
		s.setCookie(w, token, 86400)
		reply(w, 200, map[string]string{"token": token})
	})
	m.HandleFunc("POST /api/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		// Local logout remains available while Gravitas is unavailable.
		if !s.validMutation(r) {
			fail(w, 403, "invalid_origin_or_csrf")
			return
		}
		key := tokenHash(s.rawToken(r))
		err := s.store.update(func(st *State) error { delete(st.Sessions, key); return nil })
		if err != nil {
			fail(w, 500, "storage_failed")
			return
		}
		s.setCookie(w, "", -1)
		reply(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("GET /auth/gravitas/start", func(w http.ResponseWriter, r *http.Request) {
		if s.iam == nil {
			fail(w, 503, "configure_gravitas_or_use_local_development_login")
			return
		}
		if err := s.iam.Start(w, r, false); err != nil {
			fail(w, 503, "identity_unavailable")
		}
	})
	m.HandleFunc("GET /auth/gravitas/callback", func(w http.ResponseWriter, r *http.Request) {
		if s.iam == nil {
			fail(w, 503, "identity_unavailable")
			return
		}
		auth, next, err := s.iam.Callback(w, r)
		if err != nil {
			fail(w, 401, "sign_in_failed")
			return
		}
		// Haven only needs the status proof after sign-in, not upstream data or
		// refresh credentials. Reauthentication is required after eight hours.
		auth.RefreshToken = ""
		auth.AccessToken = ""
		auth.AccessExpires = 0
		expires := min(time.Now().Add(gravitas.SessionLifetime).Unix(), auth.CheckExpires)
		recorder := httptest.NewRecorder()
		if err = s.iam.SetAppSession(recorder, gravitas.SessionCookie, auth, "", time.Unix(expires, 0)); err != nil {
			fail(w, 500, "sign_in_failed")
			return
		}
		envelope := recorder.Result().Cookies()[0].Value
		token, err := s.issueSession(accountKey(auth.Issuer, auth.Subject), envelope, expires)
		if err != nil {
			fail(w, 500, "storage_failed")
			return
		}
		s.setCookie(w, token, int(expires-time.Now().Unix()))
		http.Redirect(w, r, next, http.StatusSeeOther)
	})
	m.HandleFunc("POST /api/auth/native/start", func(w http.ResponseWriter, r *http.Request) {
		if !s.validMutation(r) {
			fail(w, 403, "invalid_origin_or_csrf")
			return
		}
		var body struct {
			Challenge string `json:"challenge"`
			Platform  string `json:"platform"`
		}
		if !decode(w, r, &body) {
			return
		}
		b, e := base64.RawURLEncoding.DecodeString(body.Challenge)
		if e != nil || len(b) != 32 || (body.Platform != "" && !slices.Contains([]string{"android", "linux", "windows", "macos"}, body.Platform)) {
			fail(w, 400, "invalid_challenge")
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		s.prunePending()
		if len(s.pending) >= 100 {
			fail(w, 429, "too_many_logins")
			return
		}
		id := randomID()
		s.pending[id] = pendingLogin{Challenge: body.Challenge, Platform: body.Platform, Expires: time.Now().Add(10 * time.Minute).Unix()}
		next := "/native/complete?id=" + id
		reply(w, 200, map[string]string{"id": id, "approval_url": s.appURL + "/auth/gravitas/start?next=" + url.QueryEscape(next)})
	})
	m.HandleFunc("GET /native/complete", func(w http.ResponseWriter, r *http.Request) {
		session, _, ok := s.authorize(w, r)
		if !ok {
			return
		}
		id := r.URL.Query().Get("id")
		s.mu.Lock()
		s.prunePending()
		p, exists := s.pending[id]
		if exists && p.Approval == "approved" {
			s.mu.Unlock()
			if p.Account != session.Account {
				fail(w, 403, "invalid_approval")
				return
			}
			nativeConnected(w, p.Platform)
			return
		}
		if exists {
			// Browser Back, reload and tab restore must not invalidate a form
			// for the same account, or undo an approval waiting for the app.
			if p.Approval == "" || p.Account != session.Account {
				p.Approval = randomID()
			}
			p.Account = session.Account
			p.Envelope = session.Envelope
			s.pending[id] = p
		}
		s.mu.Unlock()
		if !exists {
			fail(w, 410, "login_expired")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, `<!doctype html><meta name="viewport" content="width=device-width"><title>Connect Haven</title><main style="font:18px system-ui;max-width:36rem;margin:10vh auto;padding:2rem"><h1>Connect Haven</h1><p>Approve only if you just started signing in on your Haven app.</p><form method="post" action="/native/approve"><input type="hidden" name="id" value="%s"><input type="hidden" name="approval" value="%s"><button style="font:inherit;padding:1rem">Connect this device</button></form></main>`, html.EscapeString(id), html.EscapeString(p.Approval))
	})
	m.HandleFunc("POST /native/approve", func(w http.ResponseWriter, r *http.Request) {
		// The form has a one-use nonce and a mandatory exact-origin check.
		if r.Header.Get("Origin") != s.appURL {
			fail(w, 403, "invalid_origin")
			return
		}
		r.Header.Set("X-Haven-CSRF", "1")
		session, _, ok := s.authorize(w, r)
		if !ok {
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		if r.ParseForm() != nil {
			fail(w, 400, "invalid_form")
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		s.prunePending()
		id := r.Form.Get("id")
		p, exists := s.pending[id]
		if !exists || p.Approval == "" || p.Approval != r.Form.Get("approval") || p.Account != session.Account {
			fail(w, 403, "invalid_approval")
			return
		}
		p.Approval = "approved"
		s.pending[id] = p
		nativeConnected(w, p.Platform)
	})
	m.HandleFunc("POST /api/auth/native/poll", func(w http.ResponseWriter, r *http.Request) {
		if !s.validMutation(r) {
			fail(w, 403, "invalid_origin_or_csrf")
			return
		}
		var body struct {
			ID       string `json:"id"`
			Verifier string `json:"verifier"`
		}
		if !decode(w, r, &body) {
			return
		}
		h := sha256.Sum256([]byte(body.Verifier))
		challenge := base64.RawURLEncoding.EncodeToString(h[:])
		s.mu.Lock()
		defer s.mu.Unlock()
		s.prunePending()
		p, exists := s.pending[body.ID]
		if !exists || challenge != p.Challenge {
			fail(w, 404, "unknown_login")
			return
		}
		if p.Approval != "approved" {
			reply(w, 202, map[string]string{"status": "pending"})
			return
		}
		token, err := s.issueSession(p.Account, p.Envelope, time.Now().Add(gravitas.SessionLifetime).Unix())
		if err != nil {
			fail(w, 500, "storage_failed")
			return
		}
		delete(s.pending, body.ID)
		reply(w, 200, map[string]string{"token": token})
	})
}
func (s *Server) prunePending() {
	for k, v := range s.pending {
		if v.Expires < time.Now().Unix() {
			delete(s.pending, k)
		}
	}
}

// The Android intent only resumes Haven. The token is redeemed separately over
// HTTPS by the initiating app's PKCE verifier; no credentials enter this link.
func nativeConnected(w http.ResponseWriter, platform string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html><meta name="viewport" content="width=device-width"><title>Haven connected</title><main style="font:18px system-ui;max-width:36rem;margin:10vh auto;padding:2rem"><h1>You're connected</h1><p>Switch back to Haven to finish signing in.</p>`)
	if platform == "android" {
		fmt.Fprint(w, `<p><a style="display:inline-block;background:#193d34;color:white;padding:1rem;text-decoration:none;border-radius:.6rem" href="intent://auth/complete#Intent;scheme=haven;package=cool.gravitas.haven;end">Return to Haven</a></p>`)
	}
	fmt.Fprint(w, `</main>`)
}
