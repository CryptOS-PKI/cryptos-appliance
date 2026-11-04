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

// The QEMU guest agent step of TestSignedISO on Proxmox's virtual hardware
// (cryptos-node#395): the node's PID 1 answers the QGA protocol on the
// org.qemu.guest_agent.0 virtio-serial port, the way Proxmox talks to a VM
// with "QEMU Guest Agent" turned on. From the host side of the port the step
// syncs with guest-sync-delimited, pings, reads guest-get-osinfo, and checks
// guest-exec is refused with CommandNotFound: a node has no shell, so the
// agent must never run anything.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"strings"
	"testing"
	"time"
)

// qgaDelimiter is the byte that resets the guest's parser when the host
// sends it, and that comes before the guest's reply to guest-sync-delimited.
const qgaDelimiter = 0xFF

// qgaReply is one QGA response: a return value or an error.
type qgaReply struct {
	Return json.RawMessage `json:"return"`
	Error  *qgaError       `json:"error"`
}

type qgaError struct {
	Class string `json:"class"`
	Desc  string `json:"desc"`
}

// qgaClient is the host side of a guest agent port: what Proxmox's
// qemu-server does over the same socket.
type qgaClient struct {
	conn    net.Conn
	r       *bufio.Reader
	dec     *json.Decoder
	timeout time.Duration
}

func newQGAClient(conn net.Conn, timeout time.Duration) *qgaClient {
	return &qgaClient{conn: conn, r: bufio.NewReader(conn), timeout: timeout}
}

func (c *qgaClient) close() error { return c.conn.Close() }

func (c *qgaClient) send(execute string, args any) error {
	req := map[string]any{"execute": execute}
	if args != nil {
		req["arguments"] = args
	}
	b, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("encode %s: %w", execute, err)
	}
	if err := c.conn.SetDeadline(time.Now().Add(c.timeout)); err != nil {
		return fmt.Errorf("set deadline: %w", err)
	}
	if _, err := c.conn.Write(b); err != nil {
		return fmt.Errorf("send %s: %w", execute, err)
	}
	return nil
}

// sync resets the guest's parser with a 0xFF, sends guest-sync-delimited with
// id, skips everything up to the guest's 0xFF (replies left over from an
// earlier client) and checks the reply after it returns id. Every later call
// reads its reply from the same stream.
func (c *qgaClient) sync(id int64) error {
	if err := c.conn.SetDeadline(time.Now().Add(c.timeout)); err != nil {
		return fmt.Errorf("set deadline: %w", err)
	}
	if _, err := c.conn.Write([]byte{qgaDelimiter}); err != nil {
		return fmt.Errorf("send the parser reset: %w", err)
	}
	if err := c.send("guest-sync-delimited", map[string]int64{"id": id}); err != nil {
		return err
	}
	skipped := 0
	for {
		b, err := c.r.ReadByte()
		if err != nil {
			return fmt.Errorf("read the sync delimiter (%d bytes skipped): %w", skipped, err)
		}
		if b == qgaDelimiter {
			break
		}
		skipped++
	}
	c.dec = json.NewDecoder(c.r)
	var r qgaReply
	if err := c.dec.Decode(&r); err != nil {
		return fmt.Errorf("read the sync reply: %w", err)
	}
	if r.Error != nil {
		return fmt.Errorf("guest-sync-delimited: %s: %s", r.Error.Class, r.Error.Desc)
	}
	var got int64
	if err := json.Unmarshal(r.Return, &got); err != nil {
		return fmt.Errorf("guest-sync-delimited returned %s, not an id: %w", r.Return, err)
	}
	if got != id {
		return fmt.Errorf("guest-sync-delimited returned %d, want %d", got, id)
	}
	return nil
}

// call sends one command and reads its reply. A refused command comes back
// as a reply with Error set, not as an error.
func (c *qgaClient) call(execute string, args any) (qgaReply, error) {
	if c.dec == nil {
		return qgaReply{}, errors.New("qga: call before a successful sync")
	}
	if err := c.send(execute, args); err != nil {
		return qgaReply{}, err
	}
	var r qgaReply
	if err := c.dec.Decode(&r); err != nil {
		return qgaReply{}, fmt.Errorf("read the %s reply: %w", execute, err)
	}
	return r, nil
}

// dialGuestAgent connects to a VM's guest agent socket and syncs, retrying
// with a new connection and a new id until it answers or limit passes. The
// agent drops a half-read request when the port has no host, so the first
// tries after a boot can go unanswered.
func dialGuestAgent(t *testing.T, sock string, limit time.Duration) *qgaClient {
	t.Helper()
	var c *qgaClient
	tries := 0
	eventually(t, "a guest-sync-delimited reply on "+sock, limit, func() (bool, string) {
		tries++
		conn, err := net.DialTimeout("unix", sock, 5*time.Second)
		if err != nil {
			return false, fmt.Sprintf("try %d: dial: %v", tries, err)
		}
		cl := newQGAClient(conn, 5*time.Second)
		id := rand.Int64N(1 << 31)
		started := time.Now()
		if err := cl.sync(id); err != nil {
			_ = cl.close()
			t.Logf("qga: try %d: sync id %d failed after %s: %v", tries, id, time.Since(started).Round(time.Millisecond), err)
			return false, fmt.Sprintf("try %d: %v", tries, err)
		}
		t.Logf("qga: try %d: synced with id %d in %s", tries, id, time.Since(started).Round(time.Millisecond))
		c = cl
		return true, ""
	})
	return c
}

func isoStepGuestAgent(t *testing.T, st *isoState) {
	v := st.node
	c := dialGuestAgent(t, v.qgaSocket(), 2*time.Minute)
	defer func() { _ = c.close() }()

	r, err := c.call("guest-ping", nil)
	if err != nil {
		t.Fatalf("guest-ping: %v", err)
	}
	t.Logf("qga: guest-ping -> return %s, error %+v", r.Return, r.Error)
	if r.Error != nil || strings.TrimSpace(string(r.Return)) != "{}" {
		t.Fatalf("guest-ping: want an empty return, got return %s, error %+v", r.Return, r.Error)
	}

	r, err = c.call("guest-get-osinfo", nil)
	if err != nil {
		t.Fatalf("guest-get-osinfo: %v", err)
	}
	t.Logf("qga: guest-get-osinfo -> return %s, error %+v", r.Return, r.Error)
	if r.Error != nil {
		t.Fatalf("guest-get-osinfo: %s: %s", r.Error.Class, r.Error.Desc)
	}
	var info struct {
		ID            string `json:"id"`
		Name          string `json:"name"`
		Version       string `json:"version"`
		KernelRelease string `json:"kernel-release"`
		Machine       string `json:"machine"`
	}
	if err := json.Unmarshal(r.Return, &info); err != nil {
		t.Fatalf("guest-get-osinfo: decode %s: %v", r.Return, err)
	}
	if info.ID != "cryptos" || info.Name != "CryptOS" {
		t.Fatalf("guest-get-osinfo: id %q name %q, want cryptos and CryptOS", info.ID, info.Name)
	}
	if info.Version != st.env.ver {
		t.Fatalf("guest-get-osinfo: version %q, want the running image's %q", info.Version, st.env.ver)
	}
	if info.KernelRelease == "" || info.Machine != "x86_64" {
		t.Fatalf("guest-get-osinfo: kernel release %q machine %q", info.KernelRelease, info.Machine)
	}

	r, err = c.call("guest-exec", map[string]any{"path": "/bin/sh", "arg": []string{"-c", "id"}})
	if err != nil {
		t.Fatalf("guest-exec: %v", err)
	}
	t.Logf("qga: guest-exec -> return %s, error %+v", r.Return, r.Error)
	if r.Error == nil || r.Error.Class != "CommandNotFound" {
		t.Fatalf("guest-exec: want a CommandNotFound error, got return %s, error %+v", r.Return, r.Error)
	}

	// The agent still answers after a refusal.
	if r, err := c.call("guest-ping", nil); err != nil || r.Error != nil {
		t.Fatalf("guest-ping after the refusal: %v %+v", err, r.Error)
	}
	note(t, fmt.Sprintf("guest-get-osinfo: %s %s, kernel %s; guest-exec refused: %s", info.Name, info.Version, info.KernelRelease, r.Error.Desc))
}
