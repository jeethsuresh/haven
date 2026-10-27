package main

import (
	"strings"
	"testing"
	"time"
)

func TestThumbnailRequestsUseSourcesAndSinksWithoutCreatingBackupCopies(t *testing.T) {
	s := fixture(t)
	source, phone := device(t, s, "alice", "android", "viewer", "source")
	sink, desktop := device(t, s, "alice", "linux", "viewer", "sink")
	viewer, web := device(t, s, "alice", "web", "viewer")
	stranger, _ := device(t, s, "bob", "web", "viewer")
	asset := publishAsset(t, s, source, manifest())
	for _, job := range value[[]Transfer](t, call(t, s, "GET", "/api/transfers", sink, nil)) {
		if w := call(t, s, "POST", "/api/transfers/"+job.ID, sink, map[string]string{"status": "complete", "sha256": asset.head().SHA256}); w.Code != 200 {
			t.Fatal(w.Body.String())
		}
	}
	body := map[string]string{"asset_id": asset.ID, "revision_id": asset.head().ID}
	if w := call(t, s, "POST", "/api/thumbnail-requests", stranger, body); w.Code != 404 {
		t.Fatal("cross-account thumbnail request allowed")
	}
	request := call(t, s, "POST", "/api/thumbnail-requests", viewer, body)
	if request.Code != 200 {
		t.Fatal(request.Body.String())
	}
	job := value[Transfer](t, request)
	if job.Purpose != "thumbnail" || job.To != web.ID || (job.From != phone.ID && job.From != desktop.ID) {
		t.Fatalf("bad thumbnail request: %+v", job)
	}
	duplicate := value[Transfer](t, call(t, s, "POST", "/api/thumbnail-requests", viewer, body))
	if duplicate.ID != job.ID {
		t.Fatal("active thumbnail request duplicated")
	}
	sender := source
	alternate := desktop.ID
	if job.From == desktop.ID {
		sender = sink
		alternate = phone.ID
	}
	signal := map[string]any{"transfer_id": job.ID, "type": "offer", "data": map[string]string{"sdp": "v=0\r\nm=application"}}
	if w := call(t, s, "POST", "/api/signals", viewer, signal); w.Code != 403 {
		t.Fatal("viewer offered as source")
	}
	if w := call(t, s, "POST", "/api/signals", sender, signal); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	inbox := value[struct {
		Signals []Signal `json:"signals"`
	}](t, call(t, s, "GET", "/api/signals", viewer, nil))
	if len(inbox.Signals) != 1 {
		t.Fatal("thumbnail signaling did not reach web viewer")
	}
	if w := call(t, s, "POST", "/api/transfers/"+job.ID, sender, map[string]string{"status": "complete"}); w.Code != 409 {
		t.Fatal("sender claimed thumbnail receipt")
	}
	call(t, s, "POST", "/api/transfers/"+job.ID, sender, map[string]string{"status": "unavailable"})
	fallback := value[Transfer](t, call(t, s, "POST", "/api/thumbnail-requests", viewer, body))
	if fallback.From != alternate {
		t.Fatal("did not try alternate source or sink")
	}
	if w := call(t, s, "POST", "/api/transfers/"+fallback.ID, viewer, map[string]string{"status": "complete"}); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	rows := value[[]struct {
		Copies   int       `json:"sink_copies"`
		Replicas []Replica `json:"replicas"`
	}](t, call(t, s, "GET", "/api/assets", viewer, nil))
	if rows[0].Copies != 1 || len(rows[0].Replicas) != 2 {
		t.Fatal("thumbnail receipt was counted as an original replica")
	}
	// An offline viewer's completed thumbnail never becomes an original source.
	call(t, s, "POST", "/api/devices/heartbeat", sink, nil)
	for _, transfer := range s.store.state.Transfers {
		if transfer.Purpose != "thumbnail" && (transfer.From == web.ID || transfer.To == web.ID) {
			t.Fatal("viewer planned for original replication")
		}
	}
}

func TestThumbnailRequestsRejectStaleRevisionsAndOfflinePeers(t *testing.T) {
	s := fixture(t)
	source, phone := device(t, s, "alice", "android", "viewer", "source")
	viewer, _ := device(t, s, "alice", "web", "viewer")
	asset := publishAsset(t, s, source, manifest())
	stale := map[string]string{"asset_id": asset.ID, "revision_id": strings.Repeat("f", 32)}
	if w := call(t, s, "POST", "/api/thumbnail-requests", viewer, stale); w.Code != 404 {
		t.Fatal("stale revision accepted")
	}
	s.store.update(func(st *State) error {
		d := st.Devices[phone.ID]
		d.Seen = time.Now().Unix() - 100
		st.Devices[d.ID] = d
		return nil
	})
	stale["revision_id"] = asset.head().ID
	if w := call(t, s, "POST", "/api/thumbnail-requests", viewer, stale); w.Code != 409 {
		t.Fatal("offline peer selected")
	}
}

func TestDeviceReportsPersistAreAccountScopedAndDoNotChangeReplicaCounts(t *testing.T) {
	s := fixture(t)
	source, phone := device(t, s, "alice", "android", "viewer", "source")
	viewer, _ := device(t, s, "alice", "web", "viewer")
	stranger, _ := device(t, s, "bob", "web", "viewer")
	asset := publishAsset(t, s, source, manifest())
	report := DeviceReport{DeviceID: "spoofed", Updated: 1, Scanned: time.Now().Unix(), PendingCount: 42, Pending: []PendingItem{{AssetID: asset.ID, RevisionID: asset.head().ID, Path: asset.Path, Direction: "send"}}, Errors: []DeviceIssue{{Code: "scan", Message: "Gallery access denied"}}}
	if w := call(t, s, "POST", "/api/reports", viewer, report); w.Code != 403 {
		t.Fatal("viewer submitted device report")
	}
	w := call(t, s, "POST", "/api/reports", source, report)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	saved := value[DeviceReport](t, w)
	if saved.DeviceID != phone.ID || saved.Updated <= 1 || saved.PendingCount != 42 {
		t.Fatal("untrusted report identity or timestamp")
	}
	reopened, err := openStore(s.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	s.store = reopened
	rows := value[[]DeviceReport](t, call(t, s, "GET", "/api/reports", viewer, nil))
	if len(rows) != 1 || rows[0].Errors[0].Message != "Gallery access denied" {
		t.Fatal("viewer lost persisted device report")
	}
	if len(value[[]DeviceReport](t, call(t, s, "GET", "/api/reports", stranger, nil))) != 0 {
		t.Fatal("cross-account report leak")
	}
	if len(s.store.state.Replicas) != 1 {
		t.Fatal("self-reported pending items changed backup receipts")
	}
	report.Errors = nil
	report.Pending = nil
	report.PendingCount = 0
	if w := call(t, s, "POST", "/api/reports", source, report); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if len(s.store.state.Reports[phone.ID].Errors) != 0 {
		t.Fatal("resolved errors not cleared")
	}
	call(t, s, "DELETE", "/api/devices/"+phone.ID, viewer, nil)
	if len(value[[]DeviceReport](t, call(t, s, "GET", "/api/reports", viewer, nil))) != 0 {
		t.Fatal("revoked device report exposed")
	}
}

func TestDeviceReportsRejectOversizedOrForeignMetadata(t *testing.T) {
	s := fixture(t)
	source, _ := device(t, s, "alice", "android", "viewer", "source")
	other, _ := device(t, s, "bob", "android", "viewer", "source")
	foreign := publishAsset(t, s, other, manifest())
	for _, r := range []DeviceReport{
		{PendingCount: -1},
		{PendingCount: 33, Pending: make([]PendingItem, 33)},
		{Errors: []DeviceIssue{{Code: "scan", Message: strings.Repeat("x", 513)}}},
		{PendingCount: 1, Pending: []PendingItem{{AssetID: foreign.ID, RevisionID: foreign.head().ID, Path: foreign.Path, Direction: "send"}}},
	} {
		if w := call(t, s, "POST", "/api/reports", source, r); w.Code != 400 {
			t.Fatal("invalid report accepted", w.Code)
		}
	}
	if w := call(t, s, "POST", "/api/reports", source, `{"thumbnail":"base64"}`); w.Code != 400 {
		t.Fatal("unknown byte payload accepted")
	}
}
