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

// The FleetOS Manager step group: cryptos-manager's own end-to-end run
// (test/e2e/esxi) drives every manager write path against the suite's live
// Root and Intermediate, the nodes the earlier steps already proved, rather
// than a second pair booted for it. run.sh builds the manager and the run
// from the pinned cryptos-manager checkout and starts their throwaway
// Postgres; this file turns SCEP on for the device enrolment, hands the run
// the nodes, an image signed in the same CI run and the SCEP address, and
// reports each of the run's steps as a row of the suite summary.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	managerRunStep   = "manager: cryptos-manager's end-to-end run against the Root and Intermediate"
	managerScepStep  = "manager: SCEP on the Intermediate with approval held, reboot, running"
	managerListen    = "127.0.0.1:18943"
	managerRunLimit  = 15 * time.Minute
	managerStepLimit = "8m"
	// The node names the run knows the nodes by. The Intermediate goes
	// first: it is the node the run's primary() targets, the one with the
	// issuing profiles, the SCEP listener and the TPM.
	managerIntName  = "suite-intermediate"
	managerRootName = "suite-root"
)

// managerResult is one step of the run, as its E2E_RESULTS_FILE records it.
type managerResult struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

// managerSteps adds the group: the SCEP switch, the run, and one row per
// step the run reported.
func (s *suite) managerSteps(st *suiteState, hier string) {
	e := s.env
	if e.managerBin == "" || e.managerE2E == "" || e.managerDB == "" || e.mgmtAlias == "" {
		s.skipStep("manager: cryptos-manager's end-to-end run",
			"no cryptos-manager checkout (run.sh builds the run from E2E_IMAGE_MANAGER_DIR)")
		return
	}
	s.step(managerScepStep, []string{hier}, func(t *testing.T) { stepManagerScepOn(t, s, st) })
	var results []managerResult
	s.step(managerRunStep, []string{hier}, func(t *testing.T) { results = stepManagerRun(t, s, st) })
	for _, r := range results {
		s.step("manager: "+r.Name, []string{managerRunStep}, func(t *testing.T) {
			note(t, r.Detail)
			switch r.Status {
			case "ok":
			case "skip":
				t.Skip(r.Detail)
			default:
				t.Fatalf("%s: %s", r.Name, r.Detail)
			}
		})
	}
}

// stepManagerScepOn turns SCEP on for the Intermediate with every initial
// enrolment held for approval, which takes a reboot to start the listener.
func stepManagerScepOn(t *testing.T, s *suite, st *suiteState) {
	st.scepOn = true
	out := applyConfig(t, st.inter, st.intConfig(s, false, true))
	if !strings.Contains(out, "requires_reboot=true") {
		t.Fatalf("config apply with SCEP on: want requires_reboot=true:\n%s", out)
	}
	st.inter.reboot(t, suiteIntCN)
	status := st.inter.status(t)
	if !strings.Contains(status, "SCEP on") || strings.Contains(status, "SCEP on (not running") {
		t.Fatalf("after the reboot, want SCEP running:\n%s", status)
	}
	note(t, "pki.scep with require_approval on the tls-server profile")
}

// stepManagerRun writes the run's nodes file, serves it the image the
// Intermediate is not running, runs it and returns its step results. It
// fails only when the run produced no results at all; a failing step of the
// run fails its own row.
func stepManagerRun(t *testing.T, s *suite, st *suiteState) []managerResult {
	e := s.env
	dir := filepath.Join(e.out, "manager")
	work := filepath.Join(dir, "work")
	creds := filepath.Join(dir, "creds")
	for _, d := range []string{work, creds} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatalf("manager dirs: %v", err)
		}
	}
	// The run's own copy of the bootstrap admin credential: the manager
	// looks for a pinned server certificate next to it, and there is none,
	// so it verifies each node against the Root and the address it dials.
	adminCert, adminKey := filepath.Join(creds, "admin.crt"), filepath.Join(creds, "admin.key")
	copyFile(t, st.admin.cert, adminCert)
	copyFile(t, st.admin.key, adminKey)
	rootPEM := filepath.Join(creds, "root.pem")
	writeFile(t, rootPEM, []byte(st.rootPEM))
	nodes := filepath.Join(dir, "nodes.yaml")
	writeFile(t, nodes, []byte(fmt.Sprintf(`nodes:
  - name: %[1]s
    endpoint: %[3]s:%[4]s
    role: intermediate
    adminCertPath: %[6]s
    adminKeyPath: %[7]s
    caCertPath: %[8]s
  - name: %[2]s
    endpoint: %[3]s:%[5]s
    role: root
    adminCertPath: %[6]s
    adminKeyPath: %[7]s
    caCertPath: %[8]s
`, managerIntName, managerRootName, e.mgmtAlias, intMgmtPort, rootMgmtPort, adminCert, adminKey, rootPEM)))

	image, imageSHA := managerImage(t, s, st)
	imageURL := serveFile(t, image)

	results := filepath.Join(dir, "results.json")
	ctx, cancel := context.WithTimeout(context.Background(), managerRunLimit)
	defer cancel()
	cmd := exec.CommandContext(ctx, e.managerE2E)
	cmd.Env = append(os.Environ(),
		"E2E_MANAGER_BIN="+e.managerBin,
		"E2E_DATABASE_URL="+e.managerDB,
		"E2E_ADMIN_EMAIL=suite-admin@cryptos.test",
		"E2E_NODES_FILE="+nodes,
		"E2E_WORKDIR="+work,
		"E2E_STEP_TIMEOUT="+managerStepLimit,
		"E2E_MANAGER_LISTEN="+managerListen,
		"E2E_RESULTS_FILE="+results,
		"E2E_ESCROW_NODE="+managerRootName,
		"E2E_SCEP_URL=http://"+net.JoinHostPort(e.hostIP, intRevPort)+"/scep",
		"E2E_IMAGE_URL="+imageURL,
		"E2E_IMAGE_SIGNATURE_PATH="+image+".sig",
		"E2E_IMAGE_SHA256="+imageSHA,
	)
	logPath := filepath.Join(e.out, "manager-e2e.log")
	logf, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("manager log: %v", err)
	}
	defer func() { _ = logf.Close() }()
	cmd.Stdout, cmd.Stderr = logf, logf
	started := time.Now()
	runErr := cmd.Run()
	took := time.Since(started).Round(time.Second)

	raw, err := os.ReadFile(results)
	if err != nil {
		log, _ := os.ReadFile(logPath)
		t.Fatalf("the run wrote no results (exit: %v) after %s:\n%s", runErr, took, lastLines(string(log), 60))
	}
	var out []managerResult
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("the run's results are not JSON: %v\n%s", err, raw)
	}
	counts := map[string]int{}
	for _, r := range out {
		counts[r.Status]++
	}
	var exitErr *exec.ExitError
	if runErr != nil && !errors.As(runErr, &exitErr) {
		t.Fatalf("the run did not finish (%v) after %s", runErr, took)
	}
	if status := st.inter.status(t); !strings.Contains(status, "Identity:        ESTABLISHED") {
		t.Fatalf("after the run, the Intermediate is not ESTABLISHED:\n%s", status)
	}
	note(t, fmt.Sprintf("%d steps in %s: %d ok, %d failed, %d skipped; log manager-e2e.log", len(out), took, counts["ok"], counts["FAIL"], counts["skip"]))
	return out
}

// managerImage picks the signed image the run stages on the Intermediate:
// of the two this CI run built (test/image/build.sh), the one the node is
// not running, so staging it is a real change. It returns its path and
// SHA-256.
func managerImage(t *testing.T, s *suite, st *suiteState) (string, string) {
	t.Helper()
	running := ""
	for _, l := range strings.Split(st.inter.mustCtl(t, "image", "status"), "\n") {
		if strings.HasPrefix(l, "Running image:") {
			running = strings.TrimSpace(strings.TrimPrefix(l, "Running image:"))
		}
	}
	if running == "" {
		t.Fatal("image status shows no running image")
	}
	for _, candidate := range []string{s.env.uki, s.env.nextUKI} {
		if candidate == "" {
			continue
		}
		if _, err := os.Stat(candidate + ".sig"); err != nil {
			continue
		}
		sum := fileSHA256(t, candidate)
		if sum != running {
			return candidate, sum
		}
	}
	t.Fatalf("no signed image other than the running %s to stage", running)
	return "", ""
}

func fileSHA256(t *testing.T, path string) string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		t.Fatalf("hash %s: %v", path, err)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// serveFile serves path over plain HTTP on loopback for the test's lifetime
// and returns its URL. The manager fetches the image itself (StageNodeImage
// takes a URL) and needs a Content-Length, which http.ServeFile sends.
func serveFile(t *testing.T, path string) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the image server: %v", err)
	}
	name := "/" + filepath.Base(path)
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != name {
				http.NotFound(w, r)
				return
			}
			http.ServeFile(w, r, path)
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(func() { _ = srv.Close() })
	return "http://" + lis.Addr().String() + name
}
