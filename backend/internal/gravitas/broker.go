package gravitas

import (
	"context"
	"regexp"
)

var brokerVerifier = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)

// The child retains its verifier. IAM enforces one-use, exact target and existing
// consent; the live status proof binds the result to the Store's login family.
func (c *Client) BrokerAuthorization(ctx context.Context, code, verifier, subject, family string) (Authorization, error) {
	if len(code) < 32 || len(code) > 2048 || !brokerVerifier.MatchString(verifier) || subject == "" || len(subject) > 256 || len(family) != 36 {
		return Authorization{}, ErrLoginRequired
	}
	auth, err := c.exchangeAuthorization(ctx, code, verifier, "")
	if err != nil {
		return Authorization{}, err
	}
	if auth.Subject != subject || auth.SessionID != family {
		return Authorization{}, ErrLoginRequired
	}
	return auth, nil
}
