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
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// refusalWant is what a maintenance node says about a config that names its
// admin by fingerprint alone.
var refusalWant = []string{"bootstrap.admin_cert_sha256", "bootstrap.admin_cert_pem"}

// fingerprintOnlyConfig returns cfg with the bootstrap admin named by its
// certificate's SHA-256 instead of the certificate, which is the one change.
func fingerprintOnlyConfig(cfg, adminPEM string) (string, error) {
	block := "  admin_cert_pem: |\n" + indentBlock(adminPEM, "    ") + "\n"
	if strings.Count(cfg, block) != 1 {
		return "", errors.New("the config does not carry the admin certificate as a block under bootstrap")
	}
	der, _ := pem.Decode([]byte(adminPEM))
	if der == nil {
		return "", errors.New("the admin certificate is not PEM")
	}
	sum := sha256.Sum256(der.Bytes)
	return strings.Replace(cfg, block, "  admin_cert_sha256: "+hex.EncodeToString(sum[:])+"\n", 1), nil
}

// isoStepRefusal sends the maintenance node the install config with the admin
// named by fingerprint only. It has to refuse it, in words that name the field,
// and stay a maintenance node that still answers, so the real install that
// follows goes to the same node.
func isoStepRefusal(t *testing.T, s *suite, st *isoState, installCfg string, maint []string) {
	t.Helper()
	cfg, err := os.ReadFile(installCfg)
	if err != nil {
		t.Fatalf("read the install config: %v", err)
	}
	bad, err := fingerprintOnlyConfig(string(cfg), st.adminPEM)
	if err != nil {
		t.Fatalf("build the fingerprint-only config: %v", err)
	}
	badPath := filepath.Join(filepath.Dir(installCfg), "install-fingerprint-only.yaml")
	writeFile(t, badPath, []byte(bad))

	out, err := run(t, "", s.env.cryptosctl, append(maint, "config", "apply", "-f", badPath)...)
	if err == nil {
		t.Fatalf("the maintenance node accepted a config naming the admin by fingerprint only:\n%s", out)
	}
	for _, want := range refusalWant {
		if !strings.Contains(out, want) {
			t.Fatalf("the refusal does not name %q:\n%s", want, out)
		}
	}
	// A refused config must not start the install: the node keeps answering
	// as the same maintenance node, now and a few seconds on.
	for range 2 {
		if status, err := run(t, "", s.env.cryptosctl, append(maint, "status")...); err != nil {
			t.Fatalf("the maintenance node stopped answering after the refusal: %v\n%s", err, status)
		}
		time.Sleep(10 * time.Second)
	}
	note(t, fmt.Sprintf("a config naming the admin by fingerprint only is refused (%s) and the node stays in maintenance", refusalWant[0]))
}

// The signed-ISO case sends the maintenance node the install config with its
// admin named by fingerprint only, which a node boot-looped on in
// v0.1.0-rc.2 (cryptos-node#417). The config it sends is the suite's own with
// that one field swapped, so the refusal can only be about the field.
func TestFingerprintOnlyConfig(t *testing.T) {
	certPEM, _, _ := generateBootstrapAdmin(t)
	cfg := isoRootYAML(string(certPEM), "e2e-iso", "tpm")

	got, err := fingerprintOnlyConfig(cfg, string(certPEM))
	if err != nil {
		t.Fatalf("fingerprintOnlyConfig: %v", err)
	}
	sum := sha256.Sum256(parsePEMCerts(t, certPEM)[0].Raw)
	if want := "admin_cert_sha256: " + hex.EncodeToString(sum[:]); !strings.Contains(got, want) {
		t.Errorf("no %q in:\n%s", want, got)
	}
	if strings.Contains(got, "admin_cert_pem") || strings.Contains(got, "BEGIN CERTIFICATE") {
		t.Errorf("the certificate is still in the config:\n%s", got)
	}
	// Everything else is the original config, line for line.
	line := "  admin_cert_sha256: " + hex.EncodeToString(sum[:]) + "\n"
	if back := strings.Replace(got, line, "  admin_cert_pem: |\n"+indentBlock(string(certPEM), "    ")+"\n", 1); back != cfg {
		t.Errorf("the rest of the config changed:\n%s", got)
	}
	if _, err := fingerprintOnlyConfig("bootstrap: {}\n", string(certPEM)); err == nil {
		t.Error("a config without the certificate: want an error")
	}
}
