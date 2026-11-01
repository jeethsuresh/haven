// Package gravitas implements the IAM server's authorization-code + PKCE protocol.
package gravitas

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const FlowCookie = "__Host-gravitas_flow"
const SessionCookie = "__Host-gravitas_session"

// SharedSignInCookie is an untrusted navigation hint, never authentication.
const SharedSignInCookie = "__Secure-gravitas_signed_in"
const SessionLifetime = 8 * time.Hour

var ErrLoginRequired = errors.New("login required")
var ErrConsentRequired = errors.New("consent required")

func HasSharedSignInHint(r *http.Request) bool {
	marker, err := r.Cookie(SharedSignInCookie)
	return err == nil && marker.Value == "1"
}

type Identity struct {
	Issuer   string `json:"issuer"`
	Subject  string `json:"sub"`
	Username string `json:"username"`
	Domain   string `json:"domain"`
	UserID   string `json:"user_id"`
}
type metadata struct {
	Issuer       string `json:"issuer"`
	Domain       string `json:"identity_domain"`
	Browser      string `json:"browser_initiation_endpoint"`
	Token        string `json:"token_endpoint"`
	Profile      string `json:"userinfo_endpoint"`
	SessionCheck string `json:"session_check_endpoint"`
}
type flow struct {
	Issuer   string
	Username string
	State    string
	Verifier string
	Next     string
	Expires  int64
	Silent   bool
}
type session struct {
	Identity      Identity
	Expires       int64
	CheckToken    string
	SessionID     string
	CheckExpires  int64
	LocalToken    string
	RefreshToken  string
	AccessExpires int64
}

type Client struct {
	refreshMu      sync.Mutex
	refreshes      map[[32]byte]*renewal
	federationMu   sync.Mutex
	federated      map[string]*Client
	federatedOrder []string
	Scope          string
	Issuer         string
	AppURL         string
	HTTP           *http.Client
	aead           cipher.AEAD
	mu             sync.Mutex
	cached         metadata
	cachedUntil    time.Time
}

func New(issuer, appURL, encodedKey string) (*Client, error) {
	issuer = strings.TrimSuffix(issuer, "/")
	appURL = strings.TrimSuffix(appURL, "/")
	for _, raw := range []string{issuer, appURL} {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" {
			return nil, errors.New("IAM and application URLs must be HTTPS origins")
		}
	}
	key, err := base64.RawURLEncoding.DecodeString(encodedKey)
	if err != nil || len(key) != 32 {
		return nil, errors.New("GRAVITAS_SESSION_KEY must be a base64url-encoded 32-byte key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Client{Issuer: issuer, AppURL: appURL, aead: aead, HTTP: &http.Client{Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (c *Client) discovery() (metadata, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Now().Before(c.cachedUntil) {
		return c.cached, nil
	}
	var m metadata
	if err := c.getJSON(c.Issuer+"/.well-known/iam-configuration", "", &m); err != nil {
		return m, err
	}
	origin, _ := url.Parse(c.Issuer)
	if m.Issuer != c.Issuer || m.Domain != origin.Hostname() {
		return m, errors.New("IAM discovery issuer/domain mismatch")
	}
	for _, raw := range []string{m.Browser, m.Token, m.Profile, m.SessionCheck} {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != origin.Scheme || u.Host != origin.Host || u.User != nil || u.Fragment != "" || u.RawQuery != "" {
			return m, errors.New("IAM discovery endpoint must belong to the configured issuer")
		}
	}
	c.cached = m
	c.cachedUntil = time.Now().Add(5 * time.Minute)
	return m, nil
}
func readJSON(resp *http.Response, out any) error {
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		return ErrUnavailable
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("IAM request failed (HTTP %d)", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		return errors.New("invalid IAM response")
	}
	return json.Unmarshal(raw, out)
}
func (c *Client) getJSON(endpoint, token string, out any) error {
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return errors.New("IAM is unavailable")
	}
	return readJSON(resp, out)
}
func random() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func SafeNext(raw string) string {
	if len(raw) > 2048 {
		return "/"
	}
	u, err := url.Parse(raw)
	if err != nil || u.IsAbs() || u.Host != "" || !strings.HasPrefix(raw, "/") || strings.HasPrefix(raw, "//") || strings.ContainsAny(raw, "\\\r\n") || strings.HasPrefix(u.Path, "//") || strings.ContainsAny(u.Path, "\\\r\n") || strings.ContainsAny(u.Fragment, "\\\r\n") {
		return "/"
	}
	if strings.HasPrefix(u.Path, "/auth/") || u.Path == "/login" {
		return "/"
	}
	next := u.RequestURI()
	if u.Fragment != "" {
		next += "#" + u.EscapedFragment()
	}
	return next
}
func (c *Client) seal(purpose string, value any) (string, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(c.aead.Seal(nonce, nonce, raw, []byte(c.AppURL+"|"+purpose))), nil
}
func (c *Client) open(purpose, encoded string, value any) error {
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(raw) < c.aead.NonceSize() {
		return errors.New("invalid authentication cookie")
	}
	raw, err = c.aead.Open(nil, raw[:c.aead.NonceSize()], raw[c.aead.NonceSize():], []byte(c.AppURL+"|"+purpose))
	if err != nil {
		return errors.New("invalid authentication cookie")
	}
	return json.Unmarshal(raw, value)
}
func cookie(w http.ResponseWriter, name, value string, age int) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", MaxAge: age, Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
}
func (c *Client) Start(w http.ResponseWriter, r *http.Request, register bool) error {
	raw := r.URL.Query().Get("username")
	if raw == "" {
		raw = r.URL.Query().Get("login_hint")
	}
	selected, username, err := c.ResolveLogin(raw, register)
	if err != nil {
		return err
	}
	c = selected
	m, err := c.discovery()
	if err != nil {
		return err
	}
	f := flow{Issuer: c.Issuer, Username: username, State: random(), Verifier: random(), Next: SafeNext(r.URL.Query().Get("next")), Expires: time.Now().Add(10 * time.Minute).Unix(), Silent: r.URL.Query().Get("prompt") == "none"}
	encoded, err := c.seal("flow", f)
	if err != nil {
		return err
	}
	h := sha256.Sum256([]byte(f.Verifier))
	q := url.Values{"callerURL": {c.AppURL}, "redirectURL": {c.AppURL + "/auth/gravitas/callback"}, "codeChallenge": {base64.RawURLEncoding.EncodeToString(h[:])}, "codeChallengeMethod": {"S256"}, "scope": {c.requestedScope()}, "state": {f.State}}
	if register {
		q.Set("screen", "register")
	}
	if f.Silent {
		q.Set("prompt", "none")
	}
	if username != "" {
		q.Set("login_hint", username)
	}
	cookie(w, FlowCookie, encoded, 600)
	http.Redirect(w, r, m.Browser+"?"+q.Encode(), http.StatusSeeOther)
	return nil
}
func (c *Client) Callback(w http.ResponseWriter, r *http.Request) (Authorization, string, error) {
	var identity Authorization
	got, err := r.Cookie(FlowCookie)
	cookie(w, FlowCookie, "", -1)
	if err != nil {
		return identity, "", errors.New("login expired; start again")
	}
	var f flow
	if err = c.open("flow", got.Value, &f); err != nil {
		return identity, "", err
	}
	q := r.URL.Query()
	if f.Expires <= time.Now().Unix() || f.Expires > time.Now().Add(11*time.Minute).Unix() || len(q["state"]) != 1 || f.State == "" || subtle.ConstantTimeCompare([]byte(f.State), []byte(q.Get("state"))) != 1 {
		return identity, "", errors.New("invalid or expired login state")
	}
	if failure := q.Get("error"); failure != "" {
		if failure == "login_required" {
			return identity, f.Next, ErrLoginRequired
		}
		if failure == "consent_required" && f.Silent {
			return identity, f.Next, ErrConsentRequired
		}
		return identity, f.Next, errors.New("IAM sign-in was not completed")
	}
	if len(q["code"]) != 1 || q.Get("code") == "" {
		return identity, "", errors.New("missing authorization code")
	}
	selected, err := c.ForIssuer(f.Issuer)
	if err != nil {
		return identity, "", err
	}
	c = selected
	identity, err = c.exchangeAuthorization(r.Context(), q.Get("code"), f.Verifier, f.Username)
	return identity, SafeNext(f.Next), err
}

func (c *Client) exchangeAuthorization(ctx context.Context, code, verifier, username string) (Authorization, error) {
	var identity Authorization
	m, err := c.discovery()
	if err != nil {
		return identity, err
	}
	form := url.Values{"grant_type": {"authorization_code"}, "code": {code}, "code_verifier": {verifier}, "redirect_uri": {c.AppURL + "/auth/gravitas/callback"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.Token, bytes.NewBufferString(form.Encode()))
	if err != nil {
		return identity, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return identity, ErrUnavailable
	}
	var tokens struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		TokenType    string `json:"token_type"`
		CheckToken   string `json:"session_check_token"`
		CheckTTL     int64  `json:"session_check_expires_in"`
		SessionID    string `json:"session_id"`
	}
	if err = readJSON(resp, &tokens); err != nil {
		return identity, err
	}
	if tokens.AccessToken == "" || !strings.EqualFold(tokens.TokenType, "Bearer") {
		return identity, errors.New("invalid IAM token response")
	}
	if err = c.getJSON(m.Profile, tokens.AccessToken, &identity.Identity); err != nil {
		return identity, err
	}
	if identity.Subject == "" || len(identity.Subject) > 256 || identity.Username == "" || identity.Domain != m.Domain || identity.UserID != "@"+identity.Username+":"+m.Domain {
		return Authorization{}, errors.New("invalid IAM identity")
	}
	if username != "" && identity.UserID != username {
		return Authorization{}, ErrLoginRequired
	}
	identity.Issuer = c.Issuer
	if tokens.CheckTTL <= 0 || tokens.CheckTTL > int64(MaxFamilyLifetime/time.Second) {
		return Authorization{}, errors.New("invalid IAM session binding")
	}
	identity.AccessToken = tokens.AccessToken
	if tokens.RefreshToken != "" {
		if tokens.ExpiresIn <= 0 || tokens.ExpiresIn > int64(SessionLifetime/time.Second) || len(tokens.RefreshToken) > 256 {
			return Authorization{}, errors.New("invalid IAM refresh binding")
		}
		identity.RefreshToken = tokens.RefreshToken
		identity.AccessExpires = time.Now().Unix() + tokens.ExpiresIn
	}
	identity.CheckToken = tokens.CheckToken
	identity.SessionID = tokens.SessionID
	identity.CheckExpires = time.Now().Unix() + tokens.CheckTTL
	bound := AppSession{Authorization: identity, ExpiresAt: time.Now().Add(SessionLifetime)}
	if err = c.Revalidate(ctx, bound); err != nil {
		return Authorization{}, err
	}
	return identity, nil
}
func (c *Client) ClearSession(w http.ResponseWriter) { cookie(w, SessionCookie, "", -1) }
func (c *Client) ValidMutation(r *http.Request) bool {
	return r.Header.Get("X-Gravitas-CSRF") == "1" && (r.Header.Get("Origin") == "" || r.Header.Get("Origin") == c.AppURL)
}

func (c *Client) requestedScope() string {
	if c.Scope == "" {
		return "profile.name"
	}
	return c.Scope
}
