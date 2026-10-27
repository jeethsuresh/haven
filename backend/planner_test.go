package main

import (
	"testing"
	"time"
)

func TestOfflineSourceFailsOverToAnotherVerifiedSink(t *testing.T) {
	s := fixture(t)
	source, phone := device(t, s, "alice", "android", "viewer", "source")
	sink, desktop := device(t, s, "alice", "linux", "viewer", "sink")
	a := publishAsset(t, s, source, manifest())
	jobs := value[[]Transfer](t, call(t, s, "GET", "/api/transfers", sink, nil))
	call(t, s, "POST", "/api/transfers/"+jobs[0].ID, sink, map[string]string{"status": "complete", "sha256": a.head().SHA256})
	_, second := device(t, s, "alice", "windows", "viewer", "sink")
	if err := s.store.update(func(st *State) error {
		d := st.Devices[phone.ID]
		d.Seen = time.Now().Add(-2 * time.Minute).Unix()
		st.Devices[phone.ID] = d
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	call(t, s, "POST", "/api/devices/heartbeat", sink, nil)
	jobs = value[[]Transfer](t, call(t, s, "GET", "/api/transfers", sink, nil))
	found := false
	for _, job := range jobs {
		if job.To == second.ID {
			found = true
			if job.From != desktop.ID {
				t.Fatal("job did not fail over to verified desktop")
			}
		}
	}
	if !found {
		t.Fatal("second sink was not scheduled")
	}
}
