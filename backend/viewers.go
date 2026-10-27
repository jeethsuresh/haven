package main

import (
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"
)

type PendingItem struct {
	AssetID    string `json:"asset_id,omitempty"`
	RevisionID string `json:"revision_id,omitempty"`
	Path       string `json:"path"`
	Direction  string `json:"direction"`
}
type DeviceIssue struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	AssetID string `json:"asset_id,omitempty"`
}
type DeviceReport struct {
	DeviceID     string        `json:"device_id"`
	Updated      int64         `json:"updated"`
	Scanned      int64         `json:"scanned"`
	PendingCount int           `json:"pending_count"`
	Pending      []PendingItem `json:"pending"`
	Errors       []DeviceIssue `json:"errors"`
}

// This creates a control-plane request, never a thumbnail upload or proxy.
func (s *Server) requestThumbnail(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var body struct {
		AssetID    string `json:"asset_id"`
		RevisionID string `json:"revision_id"`
	}
	if !decode(w, r, &body) {
		return
	}
	var out Transfer
	err := s.store.update(func(st *State) error {
		viewer, e := s.actor(st, a)
		if e != nil || !viewer.has("viewer") {
			return errors.New("forbidden")
		}
		asset, exists := st.Assets[body.AssetID]
		if !exists || asset.Account != a.Account || asset.Kind != "media" || asset.head().ID != body.RevisionID {
			return errors.New("not_found")
		}
		now := time.Now().Unix()
		active := 0
		failed := map[string]int64{}
		for id, t := range st.Transfers {
			if t.Purpose != "thumbnail" {
				continue
			}
			if t.Updated < now-86400 {
				delete(st.Transfers, id)
				continue
			}
			if t.To != viewer.ID {
				continue
			}
			if t.Status != "complete" && t.Status != "superseded" && t.Status != "unavailable" {
				if t.Updated < now-90 {
					t.Status = "superseded"
					st.Transfers[id] = t
				} else {
					active++
					if t.AssetID == asset.ID && t.RevisionID == body.RevisionID {
						out = t
						return nil
					}
				}
			}
			if t.AssetID == asset.ID && t.RevisionID == body.RevisionID && t.Status != "complete" {
				failed[t.From] = max(failed[t.From], t.Updated)
			}
		}
		if active >= 8 {
			return errors.New("too_many_requests")
		}
		candidates := []Device{}
		for _, replica := range st.Replicas {
			d := st.Devices[replica.DeviceID]
			if replica.AssetID == asset.ID && replica.RevisionID == body.RevisionID && d.ID != viewer.ID && d.Account == a.Account && !d.Revoked && d.Seen >= now-60 && (d.has("source") || d.has("sink")) {
				candidates = append(candidates, d)
			}
		}
		slices.SortFunc(candidates, func(x, y Device) int {
			if failed[x.ID] < failed[y.ID] {
				return -1
			}
			if failed[x.ID] > failed[y.ID] {
				return 1
			}
			if x.Seen > y.Seen {
				return -1
			}
			if x.Seen < y.Seen {
				return 1
			}
			return strings.Compare(x.ID, y.ID)
		})
		if len(candidates) == 0 {
			return errors.New("peer_offline")
		}
		out = Transfer{Purpose: "thumbnail", ID: randomID(), Account: a.Account, AssetID: asset.ID, RevisionID: body.RevisionID, From: candidates[0].ID, To: viewer.ID, Status: "waiting_for_peer", Updated: now}
		st.Transfers[out.ID] = out
		return nil
	})
	if err != nil {
		code := 409
		if err.Error() == "not_found" {
			code = 404
		}
		if err.Error() == "forbidden" {
			code = 403
		}
		if err.Error() == "too_many_requests" {
			code = 429
		}
		fail(w, code, err.Error())
		return
	}
	reply(w, 200, out)
}

func (s *Server) reportDevice(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	var report DeviceReport
	if !decode(w, r, &report) {
		return
	}
	if report.PendingCount < 0 || report.PendingCount > 100000000 || len(report.Pending) > 32 || len(report.Errors) > 16 || report.PendingCount < len(report.Pending) || report.Scanned < 0 || report.Scanned > time.Now().Unix()+60 {
		fail(w, 400, "invalid_report")
		return
	}
	err := s.store.update(func(st *State) error {
		d, e := s.actor(st, a)
		if e != nil || (!d.has("source") && !d.has("sink")) {
			return errors.New("forbidden")
		}
		owned := func(id string) bool {
			asset, exists := st.Assets[id]
			return id == "" || (exists && asset.Account == a.Account)
		}
		for _, p := range report.Pending {
			if len(p.Path) == 0 || len(p.Path) > 512 || strings.ContainsAny(p.Path, "\x00\r\n") || !slices.Contains([]string{"send", "receive", "index"}, p.Direction) || !owned(p.AssetID) {
				return errors.New("invalid_report")
			}
			if p.AssetID != "" {
				found := false
				for _, rev := range st.Assets[p.AssetID].Revisions {
					if rev.ID == p.RevisionID {
						found = true
					}
				}
				if !found {
					return errors.New("invalid_report")
				}
			}
		}
		for _, issue := range report.Errors {
			if len(issue.Code) == 0 || len(issue.Code) > 64 || len(issue.Message) == 0 || len(issue.Message) > 512 || !owned(issue.AssetID) {
				return errors.New("invalid_report")
			}
		}
		report.DeviceID = d.ID
		report.Updated = time.Now().Unix()
		if report.Pending == nil {
			report.Pending = []PendingItem{}
		}
		if report.Errors == nil {
			report.Errors = []DeviceIssue{}
		}
		st.Reports[d.ID] = report
		return nil
	})
	if err != nil {
		code := 400
		if err.Error() == "forbidden" {
			code = 403
		}
		fail(w, code, err.Error())
		return
	}
	reply(w, 200, report)
}
func (s *Server) reports(w http.ResponseWriter, r *http.Request) {
	a, _, ok := s.authorize(w, r)
	if !ok {
		return
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	out := []DeviceReport{}
	for id, report := range s.store.state.Reports {
		d := s.store.state.Devices[id]
		if d.Account == a.Account && !d.Revoked && (d.has("source") || d.has("sink")) {
			out = append(out, report)
		}
	}
	reply(w, 200, out)
}
