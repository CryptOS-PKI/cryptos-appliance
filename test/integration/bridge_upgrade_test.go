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

// The bridge upgrade test: a node on the bridge build (cryptos-node a77ae5b,
// the build in the field before the appliance split, which speaks the old
// cryptos.v1 API) upgrades in place to the candidate from this checkout and
// keeps its CA, its issued history and its revocations. It is booted the way
// the field runs it: a Root with the nodeid state key and Secure Boot off.
//
// test/image/build-bridge.sh builds both images, signed and anchored with one
// per-run throwaway key, and the cryptosctl of each era; test/image/run-bridge.sh
// sets the variables below. Without CRYPTOS_E2E_BRIDGE=1 the test skips.

import (
	"bytes"
	"crypto"
	"crypto/x509"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ocsp"
)

const (
	bridgeRootCN   = "CryptOS E2E Bridge Root"
	bridgeMgmtPort = "4446"
	bridgeRevPort  = "18081"
	bridgeProfile  = "tls-server"
)

type bridgeEnv struct {
	suite                   suiteEnv
	candidate, bridgeCtl    string
	bridgeVer, candidateVer string
	hostIP                  string
}

func loadBridgeEnv(t *testing.T) bridgeEnv {
	t.Helper()
	if os.Getenv("CRYPTOS_E2E_BRIDGE") != "1" {
		t.Skip("bridge upgrade test: not requested; run `task e2e:bridge` on a Linux host")
	}
	get := func(k string) string { return strings.TrimSpace(os.Getenv(k)) }
	e := bridgeEnv{
		suite: suiteEnv{
			qemu:       firstNonEmpty(get("QEMU"), "qemu-system-x86_64"),
			swtpm:      firstNonEmpty(get("SWTPM"), "swtpm"),
			ovmfCode:   get("OVMF_CODE"),
			ovmfVars:   get("OVMF_VARS"),
			uki:        get("E2E_BRIDGE_UKI"),
			accel:      firstNonEmpty(get("E2E_IMAGE_ACCEL"), "kvm:tcg"),
			out:        get("E2E_IMAGE_OUT"),
			cryptosctl: get("CRYPTOSCTL"),
		},
		candidate:    get("E2E_BRIDGE_CANDIDATE_UKI"),
		bridgeCtl:    get("E2E_BRIDGE_CRYPTOSCTL"),
		bridgeVer:    get("E2E_BRIDGE_VERSION"),
		candidateVer: get("E2E_CANDIDATE_VERSION"),
		hostIP:       get("E2E_BRIDGE_HOST_IP"),
	}
	for k, v := range map[string]string{
		"OVMF_CODE": e.suite.ovmfCode, "OVMF_VARS": e.suite.ovmfVars, "E2E_BRIDGE_UKI": e.suite.uki,
		"E2E_IMAGE_OUT": e.suite.out, "CRYPTOSCTL": e.suite.cryptosctl,
		"E2E_BRIDGE_CANDIDATE_UKI": e.candidate, "E2E_BRIDGE_CRYPTOSCTL": e.bridgeCtl,
		"E2E_BRIDGE_VERSION": e.bridgeVer, "E2E_CANDIDATE_VERSION": e.candidateVer, "E2E_BRIDGE_HOST_IP": e.hostIP,
	} {
		if v == "" {
			t.Fatalf("bridge upgrade test: %s must be set (run it through test/image/run-bridge.sh)", k)
		}
	}
	if net.ParseIP(e.hostIP) == nil {
		t.Fatalf("bridge upgrade test: E2E_BRIDGE_HOST_IP %q is not an IP", e.hostIP)
	}
	return e
}

// bridgeRootYAML is the field's shape: a Root on the nodeid state key, with a
// leaf profile and revocation published on a forward the runner reaches. A
// Root issues leaves only with the irreversible acknowledgement, which lets
// the test issue and revoke on the one node.
func bridgeRootYAML(adminPEM, hostIP string) string {
	return `apiVersion: cryptos.dev/v1alpha1
kind: MachineConfig
metadata: {name: e2e-bridge}
role: {kind: root}
network: {interface: eth0, address: ` + suiteNodeAddr + `/24, gateway: 10.0.0.1, nameservers: [10.0.0.3]}
state_key: {mode: nodeid}
bootstrap:
  admin_cert_pem: |
` + indentBlock(adminPEM, "    ") + `
pki:
  root_key_alg: ECDSA-P384
  root_subject: {common_name: "` + bridgeRootCN + `", organization: "CryptOS E2E", country: "US"}
  root_validity_years: 10
  revocation_base_url: http://` + hostIP + `:` + bridgeRevPort + `
  root_leaf_issuance: acknowledged-irreversible
  profiles:
    - name: ` + bridgeProfile + `
      key_alg: ECDSA-P384
      subject: {common_name: tls-server}
      validity_days: 30
      basic_constraints: {is_ca: false}
      key_usage: [digital_signature]
      ext_key_usage: [server_auth]
      allow_request_sans: true
`
}

// bridgeState is what one step hands the next.
type bridgeState struct {
	env      bridgeEnv
	node     *vm
	rootCert *x509.Certificate
	kept     *x509.Certificate
	revoked  *x509.Certificate
}

func TestBridgeUpgrade(t *testing.T) {
	be := loadBridgeEnv(t)
	s := &suite{t: t, env: be.suite, passed: map[string]bool{}, title: "Bridge upgrade (cryptos-node a77ae5b to the candidate)"}
	t.Cleanup(s.writeSummary)
	st := &bridgeState{env: be}

	certPEM, adminKeyPEM, _ := generateBootstrapAdmin(t)
	a := admin{cert: filepath.Join(be.suite.out, "admin.crt"), key: filepath.Join(be.suite.out, "admin.key")}
	writeFile(t, a.cert, certPEM)
	writeFile(t, a.key, adminKeyPEM)

	const (
		boot    = "bridge: boot a77ae5b as a nodeid Root, ceremony with the bridge cryptosctl"
		issue   = "bridge: issue two leaves and revoke one"
		up      = "bridge to candidate: stage with the bridge cryptosctl, activate, reboot"
		kept    = "candidate: same CA serial and key, old leaves listed, revocation on the CRL and OCSP, config kept"
		works   = "candidate: audit verify passes and a new leaf issues"
		back    = "candidate to bridge: image rollback, activate, the bridge answers"
		upAgain = "bridge to candidate again: stage, activate, back on the candidate"
	)
	s.step(boot, nil, func(t *testing.T) { bridgeStepBoot(t, s, st, string(certPEM), a) })
	s.step(issue, []string{boot}, func(t *testing.T) { bridgeStepIssue(t, s, st) })
	s.step(up, []string{issue}, func(t *testing.T) { bridgeStepUpgrade(t, st) })
	s.step(kept, []string{up}, func(t *testing.T) { bridgeStepKept(t, st) })
	s.step(works, []string{up}, func(t *testing.T) { bridgeStepWorks(t, s, st) })
	s.step(back, []string{up}, func(t *testing.T) { bridgeStepRollback(t, st) })
	s.step(upAgain, []string{back}, func(t *testing.T) {
		bridgeStepUpgrade(t, st)
		bridgeStepWorks(t, s, st)
	})

	if st.node != nil {
		st.node.stop()
	}
}

func runningVersion(imageStatus string) string {
	for _, l := range strings.Split(imageStatus, "\n") {
		if v, ok := strings.CutPrefix(l, "Running version:"); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func bridgeStepBoot(t *testing.T, s *suite, st *bridgeState, adminPEM string, a admin) {
	v := s.newVM(t, "bridge", "564d0004-0000-0000-0000-00000000e2e4", bridgeMgmtPort, []string{
		"hostfwd=tcp:" + st.env.hostIP + ":" + bridgeRevPort + "-" + suiteNodeAddr + ":80",
	}, bridgeRootYAML(adminPEM, st.env.hostIP), a)
	v.ctlBin = st.env.bridgeCtl
	st.node = v
	v.boot(t)
	out := v.mustCtl(t, "ceremony", "start", "--config", filepath.Join(v.dir, "machine.yaml"))
	for _, want := range []string{"KEY_CREATED", "CERT_SIGNED", "MANIFEST_WRITTEN", "ADMIN_ROTATED", "COMPLETE"} {
		if !strings.Contains(out, want) {
			t.Fatalf("ceremony output missing %q:\n%s", want, out)
		}
	}
	v.trustCA(t)
	st.rootCert = parsePEMCerts(t, []byte(v.mustCtl(t, "identity", "show", "-o", "pem")))[0]
	if st.rootCert.Subject.CommonName != bridgeRootCN || !st.rootCert.IsCA {
		t.Fatalf("root certificate: CN %q CA %t", st.rootCert.Subject.CommonName, st.rootCert.IsCA)
	}
	status := v.status(t)
	for _, want := range []string{"Role:            ROOT", "Identity:        ESTABLISHED", "Version:         " + st.env.bridgeVer} {
		if !strings.Contains(status, want) {
			t.Fatalf("bridge status missing %q:\n%s", want, status)
		}
	}
	// The run's key is stamped into the bridge, so it serves the upgrade
	// calls instead of Unimplemented.
	if got := runningVersion(v.mustCtl(t, "image", "status")); got != st.env.bridgeVer {
		t.Fatalf("bridge image status: running %q, want %q", got, st.env.bridgeVer)
	}
	note(t, "nodeid Root on "+st.env.bridgeVer+", Secure Boot off, image upgrade available")
}

func bridgeIssue(t *testing.T, s *suite, v *vm, name string) *x509.Certificate {
	t.Helper()
	dir := filepath.Join(s.env.out, "leaves")
	_ = os.MkdirAll(dir, 0o755)
	csr := filepath.Join(dir, name+".csr")
	writeFile(t, csr, pemBlock("CERTIFICATE REQUEST", newCSR(t, p384(t), name+".cryptos.test")))
	out := v.mustCtl(t, "ca", "issue-leaf", "--csr", csr, "--profile", bridgeProfile, "--dns", name+".cryptos.test")
	leaf := parsePEMCerts(t, []byte(out))[0]
	verifyTo(t, leaf, rootOf(t, v), nil, name+".cryptos.test", x509.ExtKeyUsageServerAuth)
	return leaf
}

func rootOf(t *testing.T, v *vm) *x509.Certificate {
	t.Helper()
	return parsePEMCerts(t, []byte(v.mustCtl(t, "identity", "show", "-o", "pem")))[0]
}

func bridgeStepIssue(t *testing.T, s *suite, st *bridgeState) {
	v := st.node
	st.kept = bridgeIssue(t, s, v, "bridge-kept")
	st.revoked = bridgeIssue(t, s, v, "bridge-revoked")
	serial := st.revoked.SerialNumber.Text(16)
	if out := v.mustCtl(t, "ca", "revoke", "--serial", serial, "--reason", "1"); !strings.Contains(strings.ToLower(out), strings.ToLower(serial)) {
		t.Fatalf("revoke output does not name %s:\n%s", serial, out)
	}
	if st.revoked.OCSPServer == nil || st.revoked.CRLDistributionPoints == nil {
		t.Fatalf("the leaf carries no OCSP or CRL pointer: OCSP %v CDP %v", st.revoked.OCSPServer, st.revoked.CRLDistributionPoints)
	}
	bridgeCheckRevocation(t, st)
	note(t, "two leaves issued, "+serial+" revoked (keyCompromise) and shown on the CRL and OCSP")
}

// bridgeCheckRevocation checks the CRL lists the revoked leaf and OCSP says
// revoked for it and good for the kept one.
func bridgeCheckRevocation(t *testing.T, st *bridgeState) {
	t.Helper()
	resp, err := http.Get(st.revoked.CRLDistributionPoints[0])
	if err != nil {
		t.Fatalf("fetch the CRL: %v", err)
	}
	crlDER, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	crl, err := x509.ParseRevocationList(crlDER)
	if err != nil {
		t.Fatalf("parse the CRL: %v", err)
	}
	if err := crl.CheckSignatureFrom(st.rootCert); err != nil {
		t.Fatalf("CRL signature: %v", err)
	}
	listed := false
	for _, rc := range crl.RevokedCertificateEntries {
		if rc.SerialNumber.Cmp(st.revoked.SerialNumber) == 0 {
			listed = true
		}
		if rc.SerialNumber.Cmp(st.kept.SerialNumber) == 0 {
			t.Fatalf("the CRL lists the kept leaf %s", st.kept.SerialNumber.Text(16))
		}
	}
	if !listed {
		t.Fatalf("the CRL (%d entries) does not list %s", len(crl.RevokedCertificateEntries), st.revoked.SerialNumber.Text(16))
	}
	for _, c := range []struct {
		leaf *x509.Certificate
		want int
	}{{st.revoked, ocsp.Revoked}, {st.kept, ocsp.Good}} {
		req, err := ocsp.CreateRequest(c.leaf, st.rootCert, &ocsp.RequestOptions{Hash: crypto.SHA256})
		if err != nil {
			t.Fatalf("OCSP request: %v", err)
		}
		resp, err := http.Post(c.leaf.OCSPServer[0], "application/ocsp-request", bytes.NewReader(req))
		if err != nil {
			t.Fatalf("OCSP %s: %v", c.leaf.OCSPServer[0], err)
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("OCSP: HTTP %d", resp.StatusCode)
		}
		r, err := ocsp.ParseResponseForCert(body, c.leaf, st.rootCert)
		if err != nil {
			t.Fatalf("OCSP: parse and verify the response: %v", err)
		}
		if r.Status != c.want {
			t.Fatalf("OCSP for %s: status %d, want %d", c.leaf.SerialNumber.Text(16), r.Status, c.want)
		}
		if c.want == ocsp.Revoked && r.RevocationReason != ocsp.KeyCompromise {
			t.Fatalf("OCSP for %s: reason %d, want keyCompromise", c.leaf.SerialNumber.Text(16), r.RevocationReason)
		}
	}
}

// bridgeStepUpgrade stages the candidate from the bridge with the bridge-era
// cryptosctl, activates it and waits for the candidate to answer on the
// current API.
func bridgeStepUpgrade(t *testing.T, st *bridgeState) {
	v := st.node
	v.ctlBin = st.env.bridgeCtl
	out := v.mustCtl(t, "image", "stage", "--image", st.env.candidate, "--signature", st.env.candidate+".sig")
	t.Logf("image stage:\n%s", out)
	if staged := v.mustCtl(t, "image", "status"); !strings.Contains(staged, "Reboot pending:   yes") {
		t.Fatalf("after staging, want a reboot pending:\n%s", staged)
	}
	bootsBefore := bootCount(v.status(t))
	started := time.Now()
	v.mustCtl(t, "image", "activate", "--confirm", bridgeRootCN)
	v.ctlBin = ""
	v.waitUp(t, bootsBefore, started, "upgrade to the candidate")
	after := v.mustCtl(t, "image", "status")
	if got := runningVersion(after); got != st.env.candidateVer || !strings.Contains(after, "Reboot pending:   no") {
		t.Fatalf("after the upgrade, want %s running and nothing pending:\n%s", st.env.candidateVer, after)
	}
	if status := v.status(t); !strings.Contains(status, "Identity:        ESTABLISHED") {
		t.Fatalf("after the upgrade:\n%s", status)
	}
	if got := rootOf(t, v); !bytes.Equal(got.Raw, st.rootCert.Raw) {
		t.Fatalf("the CA certificate changed across the upgrade: serial %s, want %s", got.SerialNumber.Text(16), st.rootCert.SerialNumber.Text(16))
	}
	note(t, "staged with the bridge cryptosctl, activated, the candidate answers on cryptos.node.v1 with the same CA")
}

func bridgeListsSerial(t *testing.T, v *vm, serial *big.Int) {
	t.Helper()
	if !listsSerial(t, v, serial, bridgeProfile) {
		t.Fatalf("list-issued does not show %s under %s", serial.Text(16), bridgeProfile)
	}
}

func bridgeStepKept(t *testing.T, st *bridgeState) {
	v := st.node
	got := rootOf(t, v)
	if got.SerialNumber.Cmp(st.rootCert.SerialNumber) != 0 || !bytes.Equal(got.RawSubjectPublicKeyInfo, st.rootCert.RawSubjectPublicKeyInfo) {
		t.Fatalf("CA serial %s (want %s) or public key changed", got.SerialNumber.Text(16), st.rootCert.SerialNumber.Text(16))
	}
	bridgeListsSerial(t, v, st.kept.SerialNumber)
	bridgeListsSerial(t, v, st.revoked.SerialNumber)
	if out := v.mustCtl(t, "ca", "revocations"); !strings.Contains(strings.ToLower(out), strings.ToLower(st.revoked.SerialNumber.Text(16))) {
		t.Fatalf("revocations do not list %s:\n%s", st.revoked.SerialNumber.Text(16), out)
	}
	bridgeCheckRevocation(t, st)
	cfg := v.mustCtl(t, "config", "get")
	for _, want := range []string{"e2e-bridge", bridgeRootCN, "mode: nodeid", "name: " + bridgeProfile, "acknowledged-irreversible",
		"http://" + st.env.hostIP + ":" + bridgeRevPort} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("config after the upgrade is missing %q:\n%s", want, cfg)
		}
	}
	note(t, "CA serial and key unchanged, both leaves listed, CRL and OCSP still say revoked (and good for the kept leaf), config kept")
}

func bridgeStepWorks(t *testing.T, s *suite, st *bridgeState) {
	v := st.node
	if out := v.mustCtl(t, "audit", "verify"); !strings.Contains(out, "audit chain intact") {
		t.Fatalf("audit verify:\n%s", out)
	}
	leaf := bridgeIssue(t, s, v, "candidate-"+time.Now().UTC().Format("150405"))
	bridgeListsSerial(t, v, leaf.SerialNumber)
	note(t, "audit chain intact; a new leaf issued and verifies to the Root")
}

func bridgeStepRollback(t *testing.T, st *bridgeState) {
	v := st.node
	v.ctlBin = ""
	if out := v.mustCtl(t, "image", "rollback"); !strings.Contains(out, "Reboot pending:   yes") {
		t.Fatalf("after the rollback, want a reboot pending:\n%s", out)
	}
	bootsBefore := bootCount(v.status(t))
	started := time.Now()
	v.mustCtl(t, "image", "activate", "--confirm", bridgeRootCN)
	v.ctlBin = st.env.bridgeCtl
	v.waitUp(t, bootsBefore, started, "rollback to the bridge")
	status := v.status(t)
	for _, want := range []string{"Identity:        ESTABLISHED", "Version:         " + st.env.bridgeVer} {
		if !strings.Contains(status, want) {
			t.Fatalf("bridge status after the rollback missing %q:\n%s", want, status)
		}
	}
	if got := runningVersion(v.mustCtl(t, "image", "status")); got != st.env.bridgeVer {
		t.Fatalf("after the rollback: running %q, want %q", got, st.env.bridgeVer)
	}
	if got := rootOf(t, v); !bytes.Equal(got.Raw, st.rootCert.Raw) {
		t.Fatal("the CA certificate changed across the rollback")
	}
	note(t, "rolled back and rebooted; the bridge answers on cryptos.v1 with the same CA")
}
