package gravitas

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"
)

const MaxFamilyLifetime = 30 * 24 * time.Hour
const RecheckInterval = 15 * time.Second

var ErrUnavailable = errors.New("Gravitas sign-in is temporarily unavailable")

// Authorization carries a confidential status-only proof. Public JSON never
// includes it; only the encrypted host-only session envelope contains it.
type Authorization struct {
	AccessToken string `json:"-"`
	Identity
	CheckToken    string `json:"-"`
	SessionID     string `json:"-"`
	CheckExpires  int64  `json:"-"`
	RefreshToken  string `json:"-"`
	AccessExpires int64  `json:"-"`
}
type AppSession struct {
	Authorization Authorization `json:"-"`
	LocalToken    string        `json:"-"`
	ExpiresAt     time.Time     `json:"-"`
}

func validBinding(a Authorization) bool {
	if len(a.CheckToken) != 43 || len(a.SessionID) != 36 || a.SessionID[8] != '-' || a.SessionID[13] != '-' || a.SessionID[18] != '-' || a.SessionID[23] != '-' {
		return false
	}
	token, err := base64.RawURLEncoding.DecodeString(a.CheckToken)
	if err != nil || len(token) != 32 {
		return false
	}
	id, err := hex.DecodeString(strings.ReplaceAll(a.SessionID, "-", ""))
	return err == nil && len(id) == 16 && a.CheckExpires > time.Now().Unix() && a.CheckExpires <= time.Now().Add(MaxFamilyLifetime+time.Minute).Unix()
}

func (c *Client) SetSession(w http.ResponseWriter, auth Authorization) error {
	return c.SetAppSession(w, SessionCookie, auth, "", time.Now().Add(SessionLifetime))
}
func (c *Client) SetAppSession(w http.ResponseWriter, name string, auth Authorization, localToken string, expires time.Time) error {
	value, expires, err := c.encodeAppSession(auth, localToken, expires)
	if err != nil {
		return err
	}
	age := max(1, int(time.Until(expires).Seconds()))
	cookie(w, name, value, age)
	return nil
}

func (c *Client) encodeAppSession(auth Authorization, localToken string, expires time.Time) (string, time.Time, error) {
	if !c.acceptsIssuer(auth.Issuer) || auth.Subject == "" || !validBinding(auth) {
		return "", expires, ErrLoginRequired
	}
	lifetime := SessionLifetime
	if auth.RefreshToken != "" {
		if len(auth.RefreshToken) > 256 || auth.AccessExpires <= time.Now().Unix() || auth.AccessExpires > time.Now().Add(SessionLifetime+time.Minute).Unix() {
			return "", expires, ErrLoginRequired
		}
		lifetime = MaxFamilyLifetime
	}
	for _, limit := range []time.Time{time.Now().Add(lifetime), time.Unix(auth.CheckExpires, 0)} {
		if limit.Before(expires) {
			expires = limit
		}
	}
	if !expires.After(time.Now()) {
		return "", expires, ErrLoginRequired
	}
	value, err := c.seal("session", session{Identity: auth.Identity, Expires: expires.Unix(), CheckToken: auth.CheckToken, SessionID: auth.SessionID, CheckExpires: auth.CheckExpires, LocalToken: localToken, RefreshToken: auth.RefreshToken, AccessExpires: auth.AccessExpires})
	if err != nil {
		return "", expires, err
	}
	if len(value) > 3800 {
		return "", expires, errors.New("application session is too large")
	}
	return value, expires, nil
}

// DecodeAppSession authenticates the local envelope only. It is used for local
// logout; protected access must call AuthenticateValue or Revalidate as well.
func (c *Client) DecodeAppSession(value string) (AppSession, error) {
	var s session
	if err := c.open("session", value, &s); err != nil {
		return AppSession{}, ErrLoginRequired
	}
	got := AppSession{Authorization: Authorization{Identity: s.Identity, CheckToken: s.CheckToken, SessionID: s.SessionID, CheckExpires: s.CheckExpires, RefreshToken: s.RefreshToken, AccessExpires: s.AccessExpires}, LocalToken: s.LocalToken, ExpiresAt: time.Unix(s.Expires, 0)}
	lifetime := SessionLifetime
	if s.RefreshToken != "" {
		lifetime = MaxFamilyLifetime
	}
	if s.Expires <= time.Now().Unix() || s.Expires > time.Now().Add(lifetime+time.Minute).Unix() || s.Expires > s.CheckExpires || !c.acceptsIssuer(s.Identity.Issuer) || s.Identity.Subject == "" || !validBinding(got.Authorization) {
		return got, ErrLoginRequired
	}
	return got, nil
}
func (c *Client) AuthenticateValue(ctx context.Context, value string) (AppSession, error) {
	got, err := c.DecodeAppSession(value)
	if err != nil {
		return got, err
	}
	if got.Authorization.AccessExpires != 0 && got.Authorization.AccessExpires <= time.Now().Unix() {
		return got, ErrLoginRequired
	}
	return got, c.Revalidate(ctx, got)
}
func (c *Client) AppSession(r *http.Request, name string) (AppSession, error) {
	value, err := r.Cookie(name)
	if err != nil {
		return AppSession{}, ErrLoginRequired
	}
	return c.AuthenticateValue(r.Context(), value.Value)
}
func (c *Client) Session(r *http.Request) (Identity, error) {
	got, err := c.AppSession(r, SessionCookie)
	return got.Authorization.Identity, err
}
func (c *Client) SessionInfo(r *http.Request) (Identity, time.Time, error) {
	got, err := c.AppSession(r, SessionCookie)
	return got.Authorization.Identity, got.ExpiresAt, err
}

// Revalidate never caches a positive status. Temporary failures deny access
// without turning an IAM outage into a logout or deleting the app cookie.
func (c *Client) Revalidate(ctx context.Context, got AppSession) error {
	a := got.Authorization
	selected, selectErr := c.ForIssuer(a.Issuer)
	if selectErr != nil {
		return ErrLoginRequired
	}
	c = selected
	if a.Issuer != c.Issuer || a.Subject == "" || !got.ExpiresAt.After(time.Now()) || !validBinding(a) {
		return ErrLoginRequired
	}
	m, err := c.discovery()
	if err != nil {
		return ErrUnavailable
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, m.SessionCheck, nil)
	if err != nil {
		return ErrUnavailable
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+a.CheckToken)
	request.Header.Set("Cache-Control", "no-store")
	response, err := c.HTTP.Do(request)
	if err != nil {
		return ErrUnavailable
	}
	if response.StatusCode == http.StatusUnauthorized {
		response.Body.Close()
		return ErrLoginRequired
	}
	var status struct {
		Active    bool   `json:"active"`
		Issuer    string `json:"iss"`
		Subject   string `json:"sub"`
		Origin    string `json:"app_origin"`
		SessionID string `json:"session_id"`
		Exp       int64  `json:"exp"`
	}
	if err = readJSON(response, &status); err != nil {
		return ErrUnavailable
	}
	if !status.Active || status.Issuer != c.Issuer || status.Subject != a.Subject || status.Origin != c.AppURL || status.SessionID != a.SessionID || status.Exp <= time.Now().Unix() || status.Exp > a.CheckExpires+5 {
		return ErrUnavailable
	}
	return nil
}
