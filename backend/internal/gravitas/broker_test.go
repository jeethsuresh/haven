package gravitas

import (
	"context"
	"strings"
	"testing"
)

func TestBrokerIdentityBindingAndOneUse(t *testing.T) {
	for _, mode := range []string{"valid", "wrong-subject", "wrong-family", "invalid-verifier"} {
		t.Run(mode, func(t *testing.T) {
			code := strings.Repeat("c", 43)
			c, calls := fixture(t, code)
			subject, family, verifier := "stable-subject", "11111111-1111-4111-8111-111111111111", strings.Repeat("v", 43)
			if mode == "wrong-subject" {
				subject = "other"
			}
			if mode == "wrong-family" {
				family = "22222222-2222-4222-8222-222222222222"
			}
			if mode == "invalid-verifier" {
				verifier = "bad"
			}
			// The existing IAM fixture enforces single-use and exact callback/verifier.
			auth, err := c.BrokerAuthorization(context.Background(), code, verifier, subject, family)
			if mode != "valid" {
				if err == nil {
					t.Fatal("accepted mismatched broker identity")
				}
				return
			}
			if err != nil || auth.Subject != subject || auth.SessionID != family {
				t.Fatal("broker authorization failed", err)
			}
			if calls.Load() != 1 {
				t.Fatal("exchange not performed")
			}
			if _, err = c.BrokerAuthorization(context.Background(), code, verifier, subject, family); err == nil {
				t.Fatal("replayed code accepted")
			}
		})
	}
}
