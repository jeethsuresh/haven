package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const backend = "http://127.0.0.1:45981"
const origin = "https://127.0.0.1:45982"

func require(err error) {
	if err != nil {
		panic(err)
	}
}

func request(method, path, token string, out any) {
	req, err := http.NewRequest(method, backend+path, nil)
	require(err)
	req.Header.Set("X-Haven-CSRF", "1")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := http.Client{Timeout: 5 * time.Second}
	res, err := client.Do(req)
	require(err)
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		panic(fmt.Sprintf("%s returned HTTP %d", path, res.StatusCode))
	}
	require(json.NewDecoder(res.Body).Decode(out))
}

// Exercise the same consent form that a TrueNAS administrator sees.
func approve(dir string) {
	rawURL, err := os.ReadFile(filepath.Join(dir, "state-b", "approval-url"))
	require(err)
	approvalURL, err := url.Parse(strings.TrimSpace(string(rawURL)))
	require(err)
	next := approvalURL.Query().Get("next")
	complete, err := url.Parse(next)
	require(err)
	id := complete.Query().Get("id")
	if complete.Path != "/native/complete" || id == "" {
		panic("Missing sink approval URL")
	}
	var session struct{ Token string }
	request("POST", "/api/dev/login", "", &session)
	browser := http.Client{Timeout: 5 * time.Second}
	formRequest := func(method, path string, form io.Reader) string {
		req, err := http.NewRequest(method, backend+path, form)
		require(err)
		req.AddCookie(&http.Cookie{Name: "haven_dev", Value: session.Token})
		req.Header.Set("Origin", origin)
		if form != nil {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		}
		res, err := browser.Do(req)
		require(err)
		defer res.Body.Close()
		if res.StatusCode != 200 {
			panic(fmt.Sprintf("%s %s returned HTTP %d", method, path, res.StatusCode))
		}
		body, err := io.ReadAll(res.Body)
		require(err)
		return string(body)
	}
	page := formRequest("GET", next, nil)
	match := regexp.MustCompile(`name="approval" value="([a-f0-9]+)"`).FindStringSubmatch(page)
	if len(match) != 2 || !strings.Contains(page, "Allow unattended sink") {
		panic("Missing unattended sink consent")
	}
	values := url.Values{"id": {id}, "approval": {match[1]}}
	formRequest("POST", "/native/approve", strings.NewReader(values.Encode()))
	var loggedOut struct{ OK bool }
	request("POST", "/api/auth/logout", session.Token, &loggedOut)
	if !loggedOut.OK {
		panic("Browser session did not end")
	}
}

func tokenPath(state string) string {
	return filepath.Join(state, fmt.Sprintf(".session-%x", sha256.Sum256([]byte("haven:"+origin))))
}

func main() {
	mode, dir := os.Args[1], os.Args[2]
	switch mode {
	case "serve":
		upstream, err := url.Parse(backend)
		require(err)
		server := &http.Server{
			Addr:              "127.0.0.1:45982",
			Handler:           httputil.NewSingleHostReverseProxy(upstream),
			ReadHeaderTimeout: 5 * time.Second,
		}
		require(server.ListenAndServeTLS(filepath.Join(dir, "ca.crt"), filepath.Join(dir, "ca.key")))
	case "seed":
		var result struct{ Token string }
		request("POST", "/api/dev/login", "", &result)
		if result.Token == "" {
			panic("Missing test source session")
		}
		require(os.WriteFile(tokenPath(filepath.Join(dir, "state-a")), []byte(result.Token), 0600))
	case "approve":
		approve(dir)
	case "paired":
		state := filepath.Join(dir, "state-b")
		raw, err := os.ReadFile(tokenPath(state))
		require(err)
		var me struct {
			DeviceID       string `json:"device_id"`
			UnattendedSink bool   `json:"unattended_sink"`
		}
		request("GET", "/api/me", string(raw), &me)
		info, err := os.Stat(tokenPath(state))
		require(err)
		if !me.UnattendedSink || me.DeviceID == "" || info.Mode().Perm() != 0600 {
			panic("The receiver did not save private unattended credentials")
		}
		if _, err := os.Stat(filepath.Join(state, "approval-url")); !os.IsNotExist(err) {
			panic("The approval URL was retained")
		}
		fmt.Println(me.DeviceID)
	case "check":
		name := os.Args[3]
		src, err := os.ReadFile(filepath.Join(dir, "repo-a", "Files", name))
		require(err)
		sink, err := os.ReadFile(filepath.Join(dir, "repo-b", "Files", name))
		require(err)
		if !bytes.Equal(src, sink) {
			panic("Received archive differs from the source")
		}
		token, err := os.ReadFile(tokenPath(filepath.Join(dir, "state-a")))
		require(err)
		var assets []struct {
			Copies int `json:"sink_copies"`
		}
		request("GET", "/api/assets", string(token), &assets)
		if len(assets) != 1 || assets[0].Copies != 2 {
			panic("Haven has not recorded both verified replicas")
		}
		fmt.Println("Received the archive unchanged and confirmed Haven's verified sink receipt.")
	default:
		panic("Unknown smoke-test action")
	}
}
