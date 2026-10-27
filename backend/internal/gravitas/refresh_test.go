package gravitas

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Advance the credential's access expiry independently of the login family.
// This reproduces returning to River hours later without a wall-clock sleep.
func renewableFixture(t *testing.T) (*Client, string, *atomic.Int32, *atomic.Bool, *atomic.Bool) {
	t.Helper()
	c, a, _ := authorizedFixture(t)
	a.RefreshToken = "refresh-original"
	a.AccessExpires = time.Now().Add(-4 * time.Hour).Unix()
	value, err := c.seal("session", session{Identity: a.Identity, Expires: a.CheckExpires, CheckToken: a.CheckToken, SessionID: a.SessionID, CheckExpires: a.CheckExpires, LocalToken: "access-expired", RefreshToken: a.RefreshToken, AccessExpires: a.AccessExpires})
	if err != nil {
		t.Fatal(err)
	}
	rotations, unavailable, revoked := &atomic.Int32{}, &atomic.Bool{}, &atomic.Bool{}
	original := c.HTTP.Transport
	c.HTTP.Transport = sessionRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/oauth/session" && revoked.Load() {
			return jsonReply(401, map[string]any{"active": false}), nil
		}
		if r.URL.Path != "/oauth/token" {
			return original.RoundTrip(r)
		}
		if unavailable.Load() {
			return jsonReply(503, map[string]any{"error": "temporarily_unavailable"}), nil
		}
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "refresh_token" || r.Form.Get("refresh_token") != "refresh-original" {
			t.Error("wrong refresh request")
		}
		if rotations.Add(1) != 1 {
			return jsonReply(400, map[string]any{"error": "invalid_grant"}), nil
		}
		return jsonReply(200, map[string]any{"access_token": "access-renewed", "refresh_token": "refresh-renewed", "token_type": "Bearer", "expires_in": 3600, "session_check_token": a.CheckToken, "session_id": a.SessionID, "session_check_expires_in": a.CheckExpires - time.Now().Unix()}), nil
	})
	return c, value, rotations, unavailable, revoked
}

func jsonReply(code int, data any) *http.Response {
	raw, _ := json.Marshal(data)
	return &http.Response{StatusCode: code, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(raw)))}
}

func TestExpiredAccessRenewsOnceForConcurrentRequestsAndResponseRetry(t *testing.T) {
	c, value, rotations, _, _ := renewableFixture(t)
	if _, err := c.AuthenticateValue(context.Background(), value); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("expired access authenticated", err)
	}
	const count = 12
	results := make(chan string, count)
	var wg sync.WaitGroup
	for range count {
		wg.Add(1)
		go func() {
			defer wg.Done()
			renewed, err := c.RefreshValue(context.Background(), value)
			if err != nil {
				t.Error(err)
			}
			results <- renewed
		}()
	}
	wg.Wait()
	close(results)
	var saved string
	for got := range results {
		if saved == "" {
			saved = got
		}
		if got != saved {
			t.Fatal("concurrent rotation produced different envelopes")
		}
	}
	retry, err := c.RefreshValue(context.Background(), value)
	if err != nil || retry != saved || rotations.Load() != 1 {
		t.Fatal("lost response could not retry safely", err, rotations.Load())
	}
	// The client's saved envelope works after a backend restart: no cache needed.
	restarted, _ := New(c.Issuer, c.AppURL, base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	restarted.HTTP = c.HTTP
	got, err := restarted.AuthenticateValue(context.Background(), saved)
	if err != nil || got.LocalToken != "access-renewed" || got.Authorization.RefreshToken != "refresh-renewed" {
		t.Fatal("saved credentials did not survive restart", err)
	}
	original, _ := c.DecodeAppSession(value)
	if got.ExpiresAt.After(original.ExpiresAt) {
		t.Fatal("renewal extended login family")
	}
	raw, _ := json.Marshal(got.Authorization)
	if strings.Contains(string(raw), "refresh-renewed") || strings.Contains(saved, "refresh-renewed") {
		t.Fatal("refresh credential leaked")
	}
}

func TestRefreshOutagePreservesEnvelopeAndRevocationDeniesCachedRenewal(t *testing.T) {
	c, value, rotations, unavailable, revoked := renewableFixture(t)
	unavailable.Store(true)
	if _, err := c.RefreshValue(context.Background(), value); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
	if _, err := c.DecodeAppSession(value); err != nil {
		t.Fatal("outage destroyed envelope", err)
	}
	unavailable.Store(false)
	if _, err := c.RefreshValue(context.Background(), value); err != nil {
		t.Fatal(err)
	}
	revoked.Store(true)
	if _, err := c.RefreshValue(context.Background(), value); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("cached renewal bypassed revocation", err)
	}
	if rotations.Load() != 1 {
		t.Fatal("revoked login consumed a token")
	}
}

func TestRefreshRejectsLegacyAndExpiredFamily(t *testing.T) {
	c, _, cookie := authorizedFixture(t)
	if _, err := c.RefreshValue(context.Background(), cookie.Value); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("legacy credential silently upgraded", err)
	}
	c, value, rotations, _, _ := renewableFixture(t)
	var s session
	_ = c.open("session", value, &s)
	s.Expires = time.Now().Add(-time.Second).Unix()
	expired, _ := c.seal("session", s)
	if _, err := c.RefreshValue(context.Background(), expired); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("expired family renewed", err)
	}
	if rotations.Load() != 0 {
		t.Fatal("expired family reached refresh endpoint")
	}
}

func TestStatusOutageAfterRotationKeepsTheReplacementForRetry(t *testing.T) {
	c, value, rotations, _, _ := renewableFixture(t)
	original := c.HTTP.Transport
	failStatus := true
	c.HTTP.Transport = sessionRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/oauth/session" && rotations.Load() > 0 && failStatus {
			return jsonReply(503, map[string]any{"error": "unavailable"}), nil
		}
		return original.RoundTrip(r)
	})
	if _, err := c.RefreshValue(context.Background(), value); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
	failStatus = false
	if _, err := c.RefreshValue(context.Background(), value); err != nil || rotations.Load() != 1 {
		t.Fatal("status outage lost rotated credentials", err)
	}
}

func TestRenewableCookieIsPersistentAndBoundToFamily(t *testing.T) {
	c, value, _, _, _ := renewableFixture(t)
	renewed, err := c.RefreshValue(context.Background(), value)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	if err = c.SetSessionValue(w, renewed); err != nil {
		t.Fatal(err)
	}
	cookie := w.Result().Cookies()[0]
	if !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteLaxMode || cookie.Domain != "" || cookie.MaxAge <= 0 {
		t.Fatal("unsafe renewed cookie")
	}
}

func TestRenewableSessionCanSurviveBeyondEightHoursWithoutExtendingCentralFamily(t *testing.T) {
	c, a, _ := authorizedFixture(t)
	a.CheckExpires = time.Now().Add(MaxFamilyLifetime).Unix()
	a.RefreshToken = "refresh-original"
	a.AccessExpires = time.Now().Add(time.Hour).Unix()
	w := httptest.NewRecorder()
	if err := c.SetAppSession(w, SessionCookie, a, "access", time.Now().Add(90*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	got, err := c.DecodeAppSession(w.Result().Cookies()[0].Value)
	if err != nil || got.ExpiresAt.Unix() != a.CheckExpires || w.Result().Cookies()[0].MaxAge < int((MaxFamilyLifetime-time.Minute).Seconds()) {
		t.Fatal("renewable login still has short lifetime", err)
	}
}
