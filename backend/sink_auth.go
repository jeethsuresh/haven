package main

import (
	"errors"
	"fmt"
	"html"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode"
)

const sinkTokenPrefix = "haven_sink_"

var errSinkUnavailable = errors.New("sink unavailable")

func validSinkName(name string) bool {
	return name != "" && len(name) <= 100 && strings.IndexFunc(name, unicode.IsControl) < 0
}

func (s *Server) authorizeSink(w http.ResponseWriter, r *http.Request, key string) (Session, string, bool) {
	// A sink credential is an API bearer for one device. It cannot sign the
	// browser in or act as an account session during another pairing.
	s.store.mu.Lock()
	device := s.store.state.Devices[s.store.state.SinkCredentials[key]]
	s.store.mu.Unlock()
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer "+sinkTokenPrefix) ||
		device.ID == "" || !canPairSink(device, device.Account) {
		fail(w, 401, "sign_in_required")
		return Session{}, "", false
	}
	switch r.Pattern {
	case "GET /api/me", "GET /api/devices", "GET /api/assets", "GET /api/reports", "GET /api/transfers", "GET /api/signals":
	case "POST /api/devices/heartbeat", "POST /api/reports", "POST /api/transfers/{id}", "POST /api/signals":
		if !s.validMutation(r) {
			fail(w, 403, "invalid_origin_or_csrf")
			return Session{}, "", false
		}
	default:
		fail(w, 403, "sink_permission_denied")
		return Session{}, "", false
	}
	return Session{Account: device.Account, DeviceID: device.ID, sinkKey: key}, key, true
}

func canPairSink(device Device, account string) bool {
	return device.ID != "" && account != "" && device.Account == account && !device.Revoked &&
		device.Platform == "linux" && device.has("sink") && !device.has("source")
}

func currentSinkKey(st *State, id string) string {
	for key, deviceID := range st.SinkCredentials {
		if deviceID == id {
			return key
		}
	}
	return ""
}

func (s *Server) issueSink(p pendingLogin) (string, error) {
	token := sinkTokenPrefix + randomID() + randomID()
	err := s.store.update(func(st *State) error {
		id := p.SinkDevice
		if id == "" {
			id = randomID()
		} else {
			if !canPairSink(st.Devices[id], p.Account) || currentSinkKey(st, id) != p.SinkKey {
				return errSinkUnavailable
			}
			delete(st.SinkCredentials, p.SinkKey)
			for key, session := range st.Sessions {
				if session.DeviceID == id {
					delete(st.Sessions, key)
				}
			}
		}
		st.Devices[id] = Device{
			ID: id, Account: p.Account, Name: p.SinkName, Platform: "linux",
			Roles: []string{"viewer", "sink"}, Seen: time.Now().Unix(),
		}
		st.SinkCredentials[tokenHash(token)] = id
		for _, asset := range st.Assets {
			if asset.Account == p.Account {
				plan(st, asset)
			}
		}
		return nil
	})
	return token, err
}

func (s *Server) sinkApprovalPage(w http.ResponseWriter, id string, p pendingLogin) {
	s.store.mu.Lock()
	devices := []Device{}
	for _, device := range s.store.state.Devices {
		if canPairSink(device, p.Account) {
			devices = append(devices, device)
		}
	}
	s.store.mu.Unlock()
	slices.SortFunc(devices, func(a, b Device) int {
		if n := strings.Compare(a.Name, b.Name); n != 0 {
			return n
		}
		return strings.Compare(a.ID, b.ID)
	})

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html><html lang="en"><meta name="viewport" content="width=device-width"><title>Pair TrueNAS sink · Haven</title><main style="font:18px system-ui;max-width:36rem;margin:10vh auto;padding:2rem"><h1>Pair TrueNAS sink</h1><p>Allow <strong>%s</strong> to handle its assigned Haven transfers while you're signed out. This access stays active until you revoke the sink in Devices.</p><form method="post" action="/native/approve"><input type="hidden" name="id" value="%s"><input type="hidden" name="approval" value="%s">`, html.EscapeString(p.SinkName), html.EscapeString(id), html.EscapeString(p.Approval))
	if len(devices) > 0 {
		fmt.Fprint(w, `<p><label>Which sink are you pairing? <select name="sink_device"><option value="">New sink</option>`)
		for _, device := range devices {
			fmt.Fprintf(w, `<option value="%s">%s (%s)</option>`, html.EscapeString(device.ID), html.EscapeString(device.Name), html.EscapeString(device.ID[:min(8, len(device.ID))]))
		}
		fmt.Fprint(w, `</select></label></p><p>Choose an existing sink only if this app still uses that sink's original datasets. Pairing replaces its old sign-in and keeps its transfer history.</p>`)
	}
	fmt.Fprint(w, `<button style="font:inherit;padding:1rem">Allow unattended sink</button></form></main>`)
}
