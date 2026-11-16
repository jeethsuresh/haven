package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
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
		for _, name := range []string{"state-a", "state-b"} {
			var result struct {
				Token string `json:"token"`
			}
			request("POST", "/api/dev/login", "", &result)
			if result.Token == "" {
				panic("Missing test session")
			}
			require(os.WriteFile(tokenPath(filepath.Join(dir, name)), []byte(result.Token), 0600))
		}
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
