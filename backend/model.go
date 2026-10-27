package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type Device struct {
	ID       string   `json:"id"`
	Account  string   `json:"-"`
	Name     string   `json:"name"`
	Platform string   `json:"platform"`
	Roles    []string `json:"roles"`
	Seen     int64    `json:"seen"`
	Revoked  bool     `json:"revoked"`
}

func (d Device) has(role string) bool {
	for _, r := range d.Roles {
		if r == role {
			return true
		}
	}
	return false
}

type Revision struct {
	ID       string `json:"id"`
	SHA256   string `json:"sha256"`
	Size     int64  `json:"size"`
	DeviceID string `json:"device_id"`
	Created  int64  `json:"created"`
}
type Asset struct {
	ID         string     `json:"id"`
	Account    string     `json:"-"`
	Kind       string     `json:"kind"`
	Path       string     `json:"path"`
	MIME       string     `json:"mime"`
	Captured   int64      `json:"captured"`
	ConflictOf string     `json:"conflict_of,omitempty"`
	Revisions  []Revision `json:"revisions"`
}

func (a Asset) head() Revision { return a.Revisions[len(a.Revisions)-1] }

type Replica struct {
	AssetID    string `json:"asset_id"`
	RevisionID string `json:"revision_id"`
	DeviceID   string `json:"device_id"`
	Verified   int64  `json:"verified"`
}
type Transfer struct {
	Purpose    string `json:"purpose,omitempty"`
	ID         string `json:"id"`
	Account    string `json:"-"`
	AssetID    string `json:"asset_id"`
	RevisionID string `json:"revision_id"`
	From       string `json:"from"`
	To         string `json:"to"`
	Status     string `json:"status"`
	Updated    int64  `json:"updated"`
}
type Session struct {
	Account  string
	Envelope string // Authenticated encryption; the IAM status proof is never plaintext on disk.
	DeviceID string
	Expires  int64
}
type State struct {
	Devices   map[string]Device
	Assets    map[string]Asset
	Replicas  []Replica
	Transfers map[string]Transfer
	Sessions  map[string]Session
	Reports   map[string]DeviceReport
}

func emptyState() State {
	return State{Devices: map[string]Device{}, Assets: map[string]Asset{}, Replicas: []Replica{}, Transfers: map[string]Transfer{}, Sessions: map[string]Session{}, Reports: map[string]DeviceReport{}}
}

// Account is hidden from API JSON but must survive snapshots. Use a separate
// persistence envelope rather than accidentally serializing ownership away.
type diskState struct {
	State          State
	DeviceOwners   map[string]string
	AssetOwners    map[string]string
	TransferOwners map[string]string
}
type Store struct {
	mu    sync.Mutex
	state State
	file  string
}

func openStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Store{state: emptyState(), file: filepath.Join(dir, "catalog.json")}
	b, err := os.ReadFile(s.file)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var d diskState
	if err = json.Unmarshal(b, &d); err != nil {
		return nil, err
	}
	if d.State.Devices == nil || d.State.Assets == nil || d.State.Sessions == nil || d.State.Transfers == nil {
		return nil, errors.New("invalid catalog")
	}
	if d.State.Reports == nil {
		d.State.Reports = map[string]DeviceReport{}
	}
	s.state = d.State
	for id, owner := range d.DeviceOwners {
		v := s.state.Devices[id]
		v.Account = owner
		s.state.Devices[id] = v
	}
	for id, owner := range d.AssetOwners {
		v := s.state.Assets[id]
		v.Account = owner
		s.state.Assets[id] = v
	}
	for id, owner := range d.TransferOwners {
		v := s.state.Transfers[id]
		v.Account = owner
		s.state.Transfers[id] = v
	}
	return s, nil
}
func snapshot(st State) diskState {
	d := diskState{State: st, DeviceOwners: map[string]string{}, AssetOwners: map[string]string{}, TransferOwners: map[string]string{}}
	for k, v := range st.Devices {
		d.DeviceOwners[k] = v.Account
	}
	for k, v := range st.Assets {
		d.AssetOwners[k] = v.Account
	}
	for k, v := range st.Transfers {
		d.TransferOwners[k] = v.Account
	}
	return d
}
func (s *Store) update(f func(*State) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Mutate a private clone, so both failed validation and failed persistence roll back.
	b, _ := json.Marshal(snapshot(s.state))
	var d diskState
	_ = json.Unmarshal(b, &d)
	for k, v := range d.DeviceOwners {
		a := d.State.Devices[k]
		a.Account = v
		d.State.Devices[k] = a
	}
	for k, v := range d.AssetOwners {
		a := d.State.Assets[k]
		a.Account = v
		d.State.Assets[k] = a
	}
	for k, v := range d.TransferOwners {
		a := d.State.Transfers[k]
		a.Account = v
		d.State.Transfers[k] = a
	}
	if err := f(&d.State); err != nil {
		return err
	}
	b, err := json.Marshal(snapshot(d.State))
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.file), ".catalog-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(b); err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(tmp.Name(), s.file); err != nil {
		return err
	}
	s.state = d.State
	dir, err := os.Open(filepath.Dir(s.file))
	if err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return nil
}
func randomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func accountKey(issuer, subject string) string { return tokenHash(issuer + "\x00" + subject) }

var digestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func validPath(kind, p string) bool {
	if p == "" || len(p) > 512 || strings.ContainsAny(p, "\\\x00\r\n") || strings.HasPrefix(p, "/") || path.Clean(p) != p {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == "." || part == ".." || strings.ContainsAny(part, `<>:"|?*`) || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") || strings.HasPrefix(part, ".haven") {
			return false
		}
		base := strings.ToUpper(strings.Split(part, ".")[0])
		if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" || regexp.MustCompile(`^(COM|LPT)[1-9]$`).MatchString(base) {
			return false
		}
	}
	prefix := map[string]string{"media": "Media/", "file": "Files/", "contact": "Structured/Contacts/", "note": "Structured/Notes/"}[kind]
	return prefix != "" && strings.HasPrefix(p, prefix) && len(p) > len(prefix)
}
func plan(st *State, a Asset) {
	h := a.head()
	for _, device := range st.Devices {
		if device.Account != a.Account || device.Revoked || !device.has("sink") {
			continue
		}
		from := ""
		var newest int64 = -1
		for _, replica := range st.Replicas {
			d := st.Devices[replica.DeviceID]
			if replica.AssetID == a.ID && replica.RevisionID == h.ID && !d.Revoked && (d.has("source") || d.has("sink")) && d.ID != device.ID && d.Seen > newest {
				from, newest = d.ID, d.Seen
			}
		}
		already := false
		for _, r := range st.Replicas {
			if r.AssetID == a.ID && r.RevisionID == h.ID && r.DeviceID == device.ID {
				already = true
			}
		}
		for key, t := range st.Transfers {
			if t.Purpose != "thumbnail" && t.AssetID == a.ID && t.RevisionID == h.ID && t.To == device.ID && t.Status != "superseded" {
				already = true
				if t.Status != "complete" && from != "" && from != t.From && st.Devices[t.From].Seen < time.Now().Add(-60*time.Second).Unix() {
					t.From, t.Status, t.Updated = from, "waiting_for_peer", time.Now().Unix()
					st.Transfers[key] = t
				}
			}
		}
		if already {
			continue
		}
		if from == "" {
			continue
		}
		t := Transfer{ID: randomID(), Account: a.Account, AssetID: a.ID, RevisionID: h.ID, From: from, To: device.ID, Status: "waiting_for_peer", Updated: time.Now().Unix()}
		st.Transfers[t.ID] = t
	}
}
