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
	managerRunStep       = "manager: cryptos-manager's end-to-end run against the Root and Intermediate"
	managerScepStep      = "manager: SCEP on the Intermediate with approval held, reboot, running"
	managerSpareStep     = "manager: a fresh spare node for the run to link, restore onto and decommission"
	managerSpareRowsStep = "manager: the linking, escrow-import and decommission steps ran, none skipped"
	managerListen        = "127.0.0.1:18943"
	managerRunLimit      = 15 * time.Minute
	managerStepLimit     = "8m"
	// The node names the run knows the nodes by. The Intermediate goes
	// first: it is the node the run's primary() targets, the one with the
	// issuing profiles, the SCEP listener and the TPM.
	managerIntName  = "suite-intermediate"
	managerRootName = "suite-root"
	// managerSpareName is the fresh node the run may link, restore the Root's
	// escrowed key onto and decommission: it permanently changes the node, so
	// it is never the Root or the Intermediate.
	managerSpareName = "suite-spare"

	// The run's steps that need that node, by the name each reports. They skip
	// without a spare, and a skip shows green.
	managerLinkRow         = "enrollment/link-approve-and-reject"
	managerEscrowImportRow = "escrow/import-onto-spare"
	managerDecommissionRow = "decommission/spare-node"
)

// requireSpareRows fails when a step that needs the spare node did not run,
// because a spare was configured and the run was meant to use it. A step that
// ran and failed reports itself, so this checks only for a skip or a missing
// row.
func requireSpareRows(results []managerResult) error {
	var notRun []string
	for _, want := range []string{managerLinkRow, managerEscrowImportRow, managerDecommissionRow} {
		ran := false
		for _, r := range results {
			if r.Name == want && r.Status != "skip" {
				ran = true
			}
		}
		if !ran {
			notRun = append(notRun, want)
		}
	}
	if len(notRun) > 0 {
		return fmt.Errorf("with a spare node configured, these steps must run, and they were skipped or missing: %s", strings.Join(notRun, ", "))
	}
	return nil
}

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
	s.step(managerSpareStep, []string{"console reset over the serial line, on a throwaway node"},
		func(t *testing.T) { stepManagerSpare(t, s, st) })
	var results []managerResult
	s.step(managerRunStep, []string{hier}, func(t *testing.T) { results = stepManagerRun(t, s, st) })
	s.step(managerSpareRowsStep, []string{managerRunStep}, func(t *testing.T) {
		if err := requireSpareRows(results); err != nil {
			t.Fatal(err)
		}
	})
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

// stepManagerSpare replaces the console-reset step's throwaway node with a
// fresh one on its port, so the VM count stays at three. The run restores the
// Root's escrowed key onto the spare, which a node that already has an
// identity refuses, and the console reset left that node wiped and
// re-provisioning.
func stepManagerSpare(t *testing.T, s *suite, st *suiteState) {
	if st.spare != nil {
		st.spare.stop()
	}
	st.spare = s.newVM(t, "link-spare", "564d0004-0000-0000-0000-00000000e2e4", spareMgmtPort, nil, rootYAML(st.adminPEM, "e2e-link-spare"), st.admin)
	st.spare.boot(t)
	if status := st.spare.status(t); !strings.Contains(status, "Identity:        NONE") {
		t.Fatalf("fresh spare: want no identity:\n%s", status)
	}
	note(t, "a fresh node on port "+spareMgmtPort+", no identity, its management certificate pinned")
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
	// The spare has no CA yet, so it is linked by pinning its own management
	// certificate, which the restore of the Root's key then replaces: the run
	// dials it without verification afterwards.
	sparePin := filepath.Join(creds, "spare.pem")
	copyFile(t, st.spare.trust, sparePin)
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
  - name: %[9]s
    endpoint: %[3]s:%[10]s
    role: root
    adminCertPath: %[6]s
    adminKeyPath: %[7]s
    caCertPath: %[11]s
    insecureSkipNodeVerify: true
    spare: true
`, managerIntName, managerRootName, e.mgmtAlias, intMgmtPort, rootMgmtPort, adminCert, adminKey, rootPEM,
		managerSpareName, spareMgmtPort, sparePin)))

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
