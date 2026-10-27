package gravitas

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type sessionRoundTrip func(*http.Request) (*http.Response, error)

func (f sessionRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func authorizedFixture(t *testing.T) (*Client, Authorization, *http.Cookie) {
	t.Helper()
	c, _ := fixture(t)
	f, flowCookie, _ := start(t, c)
	r := httptest.NewRequest("GET", c.AppURL+"/auth/gravitas/callback?code=one-use-code&state="+f.State, nil)
	r.AddCookie(flowCookie)
	auth, _, err := c.Callback(httptest.NewRecorder(), r)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	if err = c.SetSession(w, auth); err != nil {
		t.Fatal(err)
	}
	return c, auth, w.Result().Cookies()[0]
}
func TestStatusCheckedEveryTimeAndRevocationIsNotCached(t *testing.T) {
	c, auth, cookie := authorizedFixture(t)
	original := c.HTTP.Transport
	var checks atomic.Int32
	var revoked atomic.Bool
	c.HTTP.Transport = sessionRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/oauth/session" {
			checks.Add(1)
			if r.Header.Get("Cache-Control") != "no-store" {
				t.Error("missing no-store")
			}
			if revoked.Load() {
				return &http.Response{StatusCode: 401, Body: io.NopCloser(strings.NewReader(`{"active":false,"error":"invalid_token"}`)), Header: make(http.Header)}, nil
			}
		}
		return original.RoundTrip(r)
	})
	req := httptest.NewRequest("GET", c.AppURL+"/", nil)
	req.AddCookie(cookie)
	for i := 0; i < 2; i++ {
		if _, err := c.Session(req); err != nil {
			t.Fatal(err)
		}
	}
	if checks.Load() != 2 {
		t.Fatal("positive status was cached")
	}
	revoked.Store(true)
	if _, err := c.Session(req); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("revocation did not deny access")
	}
	raw, _ := json.Marshal(auth)
	if strings.Contains(string(raw), auth.CheckToken) || strings.Contains(cookie.Value, auth.CheckToken) {
		t.Fatal("confidential proof leaked")
	}
}
func TestUnavailableOrMismatchedStatusRetainsLocallyDecodableSession(t *testing.T) {
	for _, kind := range []string{"network", "503", "malformed", "issuer", "subject", "origin", "family", "expiry", "inactive200"} {
		t.Run(kind, func(t *testing.T) {
			c, auth, cookie := authorizedFixture(t)
			c.HTTP.Transport = sessionRoundTrip(func(r *http.Request) (*http.Response, error) {
				if kind == "network" {
					return nil, errors.New("offline")
				}
				code := 200
				body := map[string]any{"active": true, "iss": c.Issuer, "sub": auth.Subject, "app_origin": c.AppURL, "session_id": auth.SessionID, "exp": auth.CheckExpires}
				switch kind {
				case "503":
					code = 503
				case "issuer":
					body["iss"] = "https://other.example"
				case "subject":
					body["sub"] = "other"
				case "origin":
					body["app_origin"] = "https://other.example"
				case "family":
					body["session_id"] = "other"
				case "expiry":
					body["exp"] = time.Now().Add(-time.Minute).Unix()
				case "inactive200":
					body["active"] = false
				}
				raw, _ := json.Marshal(body)
				if kind == "malformed" {
					raw = []byte("invalid-json")
				}
				return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(string(raw))), Header: make(http.Header)}, nil
			})
			req := httptest.NewRequest("GET", c.AppURL+"/", nil)
			req.AddCookie(cookie)
			if _, err := c.Session(req); !errors.Is(err, ErrUnavailable) {
				t.Fatalf("unavailable status not distinguished: %v", err)
			}
			decoded, err := c.DecodeAppSession(cookie.Value)
			if err != nil || decoded.Authorization.CheckToken != auth.CheckToken {
				t.Fatal("temporary failure destroyed local session")
			}
		})
	}
}
func TestLegacyCookieAndUnboundProofCannotAuthenticate(t *testing.T) {
	c, auth, _ := authorizedFixture(t)
	legacy, err := c.seal("session", session{Identity: auth.Identity, Expires: time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.AuthenticateValue(httptest.NewRequest("GET", "/", nil).Context(), legacy); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("legacy unbound session accepted")
	}
	auth.SessionID = ""
	if err = c.SetSession(httptest.NewRecorder(), auth); !errors.Is(err, ErrLoginRequired) {
		t.Fatal("unbound proof accepted")
	}
}
