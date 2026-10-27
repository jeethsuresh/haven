package gravitas

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// A bounded retry window lets concurrent tabs and a lost HTTP response retrieve
// the same rotation, rather than consuming a single-use refresh token twice.
// Successful clients persist the new envelope; sessions survive process restarts.
type renewal struct {
	done    chan struct{}
	value   string
	err     error
	expires time.Time
}

func (c *Client) RefreshValue(ctx context.Context, value string) (string, error) {
	got, err := c.DecodeAppSession(value)
	if err != nil {
		return "", err
	}
	if err = c.Revalidate(ctx, got); err != nil {
		return "", err
	}
	a := got.Authorization
	if a.RefreshToken == "" {
		return "", ErrLoginRequired
	}
	if a.AccessExpires > time.Now().Add(time.Minute).Unix() {
		return value, nil
	}
	key := sha256.Sum256([]byte(a.Issuer + "|" + a.RefreshToken))
	c.refreshMu.Lock()
	if c.refreshes == nil {
		c.refreshes = make(map[[32]byte]*renewal)
	}
	for k, entry := range c.refreshes {
		if time.Now().After(entry.expires) {
			delete(c.refreshes, k)
		}
	}
	if entry := c.refreshes[key]; entry != nil {
		c.refreshMu.Unlock()
		select {
		case <-ctx.Done():
			return "", ErrUnavailable
		case <-entry.done:
			return c.validateRenewal(ctx, entry.value, entry.err)
		}
	}
	if len(c.refreshes) >= 4096 {
		c.refreshMu.Unlock()
		return "", ErrUnavailable
	}
	entry := &renewal{done: make(chan struct{}), expires: time.Now().Add(2 * time.Minute)}
	c.refreshes[key] = entry
	c.refreshMu.Unlock()
	entry.value, entry.err = c.rotate(ctx, got)
	c.refreshMu.Lock()
	if entry.err != nil {
		delete(c.refreshes, key)
	}
	close(entry.done)
	c.refreshMu.Unlock()
	return c.validateRenewal(ctx, entry.value, entry.err)
}

func (c *Client) validateRenewal(ctx context.Context, value string, err error) (string, error) {
	if err != nil {
		return "", err
	}
	got, err := c.DecodeAppSession(value)
	if err != nil {
		return "", err
	}
	if err = c.Revalidate(ctx, got); err != nil {
		return "", err
	}
	return value, nil
}

func (c *Client) rotate(ctx context.Context, got AppSession) (string, error) {
	a := got.Authorization
	selected, err := c.ForIssuer(a.Issuer)
	if err != nil {
		return "", ErrLoginRequired
	}
	m, err := selected.discovery()
	if err != nil {
		return "", ErrUnavailable
	}
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {a.RefreshToken}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.Token, bytes.NewBufferString(form.Encode()))
	if err != nil {
		return "", ErrUnavailable
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := selected.HTTP.Do(req)
	if err != nil {
		return "", ErrUnavailable
	}
	defer resp.Body.Close()
	var tokens struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		TokenType    string `json:"token_type"`
		ExpiresIn    int64  `json:"expires_in"`
		CheckToken   string `json:"session_check_token"`
		CheckTTL     int64  `json:"session_check_expires_in"`
		SessionID    string `json:"session_id"`
		Error        string `json:"error"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&tokens) != nil {
		return "", ErrUnavailable
	}
	if resp.StatusCode == 400 && tokens.Error == "invalid_grant" {
		return "", ErrLoginRequired
	}
	if resp.StatusCode != 200 || !strings.EqualFold(tokens.TokenType, "Bearer") || tokens.AccessToken == "" || len(tokens.AccessToken) > 256 || tokens.RefreshToken == "" || len(tokens.RefreshToken) > 256 || tokens.ExpiresIn <= 0 || tokens.ExpiresIn > int64(SessionLifetime/time.Second) || tokens.SessionID != a.SessionID || tokens.CheckTTL <= 0 || tokens.CheckTTL > int64(MaxFamilyLifetime/time.Second) {
		return "", ErrUnavailable
	}
	// The status proof binds the refreshed credential to the original account,
	// issuer and app. A refresh can never extend the original login family.
	a.AccessToken = tokens.AccessToken
	a.RefreshToken = tokens.RefreshToken
	a.AccessExpires = time.Now().Unix() + tokens.ExpiresIn
	a.CheckToken = tokens.CheckToken
	a.CheckExpires = min(a.CheckExpires, time.Now().Unix()+tokens.CheckTTL)
	value, _, err := c.encodeAppSession(a, a.AccessToken, got.ExpiresAt)
	return value, err
}

// SetSessionValue writes only a locally authenticated envelope. Callers must
// revalidate centrally before using it to grant protected access.
func (c *Client) SetSessionValue(w http.ResponseWriter, value string) error {
	got, err := c.DecodeAppSession(value)
	if err != nil {
		return err
	}
	cookie(w, SessionCookie, value, max(1, int(time.Until(got.ExpiresAt).Seconds())))
	return nil
}
