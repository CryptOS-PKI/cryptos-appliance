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

// The sign-time anchor steps of TestBridgeUpgrade: the candidate built the
// way a release asset is (unsigned, no anchor compiled into /init), then
// signed with `cryptosctl image sign` and a throwaway key of its own, the
// way an operator signs a downloaded image. The signing step appends the
// certificate to the UKI's .initrd, cryptos-switchroot hands it to init, and
// the node checks the next image against it. test/image/build-bridge.sh
// builds both images and signs them.

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const signedMgmtPort = "4447"

type signedEnv struct {
	uki, nextUKI, cert string
	ver, nextVer       string
}

type signedState struct {
	env      signedEnv
	admin    admin
	adminPEM string
	node     *vm
}

func signedStepVerify(t *testing.T, ss *signedState) {
	certPEM, err := os.ReadFile(ss.env.cert)
	if err != nil {
		t.Fatalf("read the signing certificate: %v", err)
	}
	cert := parsePEMCerts(t, certPEM)[0]
	pub, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		t.Fatalf("the signing certificate holds a %T, want RSA", cert.PublicKey)
	}
	var verified []string
	for _, uki := range []string{ss.env.uki, ss.env.nextUKI} {
		out := mustRun(t, "sbverify", "--cert", ss.env.cert, uki)
		if !strings.Contains(out, "Signature verification OK") {
			t.Fatalf("sbverify --cert %s %s:\n%s", ss.env.cert, uki, out)
		}
		img, err := os.ReadFile(uki)
		if err != nil {
			t.Fatalf("read %s: %v", uki, err)
		}
		sig, err := os.ReadFile(uki + ".sig")
		if err != nil {
			t.Fatalf("read the detached signature: %v", err)
		}
		digest := sha256.Sum256(img)
		if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, digest[:], sig); err != nil {
			t.Fatalf("%s.sig does not verify against the signing certificate: %v", uki, err)
		}
		verified = append(verified, filepath.Base(uki))
	}
	note(t, "sbverify: Signature verification OK for "+strings.Join(verified, " and ")+"; both .sig files verify")
}

func signedStepBoot(t *testing.T, s *suite, ss *signedState) {
	v := s.newVMFrom(t, ss.env.uki, "signed", "564d0005-0000-0000-0000-00000000e2e5", signedMgmtPort, nil,
		rootYAML(ss.adminPEM, "e2e-signed"), ss.admin)
	ss.node = v
	v.boot(t)
	out := v.mustCtl(t, "ceremony", "start", "--config", filepath.Join(v.dir, "machine.yaml"))
	if !strings.Contains(out, "COMPLETE") {
		t.Fatalf("ceremony did not complete:\n%s", out)
	}
	v.trustCA(t)
	// A node with no anchor answers this with Unimplemented ("image upgrade
	// is not available on this server"); the signed image has none compiled
	// in, so an answer means the sign-time anchor reached init.
	status, err := v.ctl("", "image", "status")
	if err != nil {
		t.Fatalf("image status on the signed node: %v\n%s", err, status)
	}
	if got := runningVersion(status); got != ss.env.ver {
		t.Fatalf("image status: running %q, want %q:\n%s", got, ss.env.ver, status)
	}
	note(t, "booted "+ss.env.ver+" (no build-time anchor); image status answers, so upgrades are available")
}

func signedStepUpgrade(t *testing.T, ss *signedState, otherKeyUKI string) {
	v := ss.node
	idBefore := v.mustCtl(t, "identity", "show", "-o", "pem")
	if out, err := v.ctl("", "image", "stage", "--image", otherKeyUKI, "--signature", otherKeyUKI+".sig"); err == nil {
		t.Fatalf("an image signed by another key was staged:\n%s", out)
	}
	if st := v.mustCtl(t, "image", "status"); !strings.Contains(st, "Reboot pending:   no") {
		t.Fatalf("after the refused stage, want nothing pending:\n%s", st)
	}
	out := v.mustCtl(t, "image", "stage", "--image", ss.env.nextUKI, "--signature", ss.env.nextUKI+".sig")
	t.Logf("image stage:\n%s", out)
	if staged := v.mustCtl(t, "image", "status"); !strings.Contains(staged, "Reboot pending:   yes") {
		t.Fatalf("after staging, want a reboot pending:\n%s", staged)
	}
	bootsBefore := bootCount(v.status(t))
	started := time.Now()
	v.mustCtl(t, "image", "activate", "--confirm", suiteRootCN)
	v.waitUp(t, bootsBefore, started, "upgrade to the second signed image")
	after := v.mustCtl(t, "image", "status")
	if got := runningVersion(after); got != ss.env.nextVer || !strings.Contains(after, "Reboot pending:   no") {
		t.Fatalf("after the upgrade, want %s running and nothing pending:\n%s", ss.env.nextVer, after)
	}
	if id := v.mustCtl(t, "identity", "show", "-o", "pem"); id != idBefore {
		t.Fatal("the identity changed across the upgrade")
	}
	note(t, "the bridge-key candidate was refused; "+ss.env.nextVer+" staged, activated and running with the same identity")
}
