//go:build integration

package integration

/*
Copyright The CryptOS Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

// fakeGuest answers QGA requests on one end of a pipe the way the node's
// agent does: a 0xFF from the host is skipped, guest-sync-delimited is
// answered after a 0xFF of its own, and anything not in replies is
// CommandNotFound. stale is written first, as a reply left over from an
// earlier connection would be.
func fakeGuest(t *testing.T, conn net.Conn, stale string, replies map[string]string, syncOffset int64) {
	t.Helper()
	go func() {
		defer func() { _ = conn.Close() }()
		// net.Pipe is synchronous, so the stale bytes go out beside the
		// reads, and before the first reply.
		staleDone := make(chan struct{})
		go func() {
			defer close(staleDone)
			if stale != "" {
				_, _ = conn.Write([]byte(stale))
			}
		}()
		r := bufio.NewReader(conn)
		for {
			b, err := r.Peek(1)
			if err != nil {
				return
			}
			if b[0] == 0xFF {
				_, _ = r.ReadByte()
				continue
			}
			var req struct {
				Execute   string          `json:"execute"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.NewDecoder(r).Decode(&req); err != nil {
				return
			}
			var out string
			switch {
			case req.Execute == "guest-sync-delimited":
				var a struct {
					ID int64 `json:"id"`
				}
				_ = json.Unmarshal(req.Arguments, &a)
				rb, _ := json.Marshal(map[string]int64{"return": a.ID + syncOffset})
				out = "\xff" + string(rb) + "\n"
			case replies[req.Execute] != "":
				out = replies[req.Execute] + "\n"
			default:
				out = `{"error": {"class": "CommandNotFound", "desc": "Command ` + req.Execute + ` has been disabled"}}` + "\n"
			}
			<-staleDone
			if _, err := conn.Write([]byte(out)); err != nil {
				return
			}
			// One request per decoder: the fake reads them one at a time.
			r = bufio.NewReader(conn)
		}
	}()
}

func TestQGAClientSyncAndCall(t *testing.T) {
	host, guest := net.Pipe()
	fakeGuest(t, guest, `{"return": {}}`+"\n", map[string]string{
		"guest-ping":       `{"return": {}}`,
		"guest-get-osinfo": `{"return": {"id": "cryptos", "name": "CryptOS", "version": "v0.1.0-rc.2"}}`,
	}, 0)
	c := newQGAClient(host, 5*time.Second)
	defer func() { _ = c.close() }()

	if err := c.sync(4711); err != nil {
		t.Fatalf("sync: %v", err)
	}
	r, err := c.call("guest-ping", nil)
	if err != nil {
		t.Fatalf("guest-ping: %v", err)
	}
	if r.Error != nil || strings.TrimSpace(string(r.Return)) != "{}" {
		t.Fatalf("guest-ping: want an empty return, got %+v", r)
	}
	r, err = c.call("guest-get-osinfo", nil)
	if err != nil {
		t.Fatalf("guest-get-osinfo: %v", err)
	}
	var info struct {
		ID      string `json:"id"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(r.Return, &info); err != nil || info.ID != "cryptos" || info.Version != "v0.1.0-rc.2" {
		t.Fatalf("guest-get-osinfo: %+v (%v)", r, err)
	}
	r, err = c.call("guest-exec", map[string]any{"path": "/bin/sh"})
	if err != nil {
		t.Fatalf("guest-exec: %v", err)
	}
	if r.Error == nil || r.Error.Class != "CommandNotFound" {
		t.Fatalf("guest-exec: want a CommandNotFound error, got %+v", r)
	}
}

func TestQGAClientSyncWrongID(t *testing.T) {
	host, guest := net.Pipe()
	fakeGuest(t, guest, "", nil, 1)
	c := newQGAClient(host, 5*time.Second)
	defer func() { _ = c.close() }()
	err := c.sync(10)
	if err == nil || !strings.Contains(err.Error(), "want 10") {
		t.Fatalf("a sync answered with another id must fail, got %v", err)
	}
}

func TestQGAClientTimeout(t *testing.T) {
	host, guest := net.Pipe()
	// A guest that reads but never answers, as a port with no agent behind it.
	go func() {
		buf := make([]byte, 512)
		for {
			if _, err := guest.Read(buf); err != nil {
				return
			}
		}
	}()
	defer func() { _ = guest.Close() }()
	c := newQGAClient(host, 200*time.Millisecond)
	defer func() { _ = c.close() }()
	if err := c.sync(1); err == nil {
		t.Fatal("a silent guest must time out")
	}
}
