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

// The signed-ISO test (cryptos-appliance#83): an unsigned ISO made the way
// the release makes its assets, signed afterwards with `cryptosctl image
// sign` and a throwaway key, the way an operator signs a downloaded ISO.
// The signing step rewrites both copies of the UKI inside the ISO, the El
// Torito EFI boot image's BOOTX64.EFI and /cryptos.uki, and writes the
// signed UKI and its .sig beside the ISO. The test checks both copies with
// xorriso, mtools and sbverify, boots the ISO on a blank disk, installs a
// node from it over the maintenance API the way an operator does, and
// upgrades that node to a second image signed with the same key.
//
// It also boots the ISO on a link with no DHCP server and reaches the
// maintenance API on the link-local address the node gives itself
// (cryptos-node#381).
//
// test/image/build-iso.sh builds and signs both ISOs; test/image/run-iso.sh
// sets the variables below. Without CRYPTOS_E2E_ISO=1 the test skips.

import (
	"bytes"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	isoMgmtPort  = "4448"
	isoMaintPort = "4449"
	// QEMU's user network leases its first DHCP address, .15, to the guest.
	// That is where the node booted from the ISO serves the maintenance API,
	// before it has the static address its config gives it.
	isoMaintAddr = "10.0.0.15"
	// The VM's first virtio disk.
	isoInstallDisk = "/dev/vda"
	// isoLinkLocalMAC is the NIC address of the VM on the link with no DHCP
	// server, so the link-local address the node derives from it is known.
	isoLinkLocalMAC = "52:54:00:4c:4c:01"
)

type isoEnv struct {
	suite                   suiteEnv
	iso, uki, nextUKI, cert string
	ver, nextVer            string
	// tap is a host tap device on a link with no DHCP server, with a
	// 169.254.0.0/16 address on the host side; empty skips that step.
	tap string
}

func loadISOEnv(t *testing.T) isoEnv {
	t.Helper()
	if os.Getenv("CRYPTOS_E2E_ISO") != "1" {
		t.Skip("signed-ISO test: not requested; run `task e2e:iso` on a Linux host")
	}
	get := func(k string) string { return strings.TrimSpace(os.Getenv(k)) }
	e := isoEnv{
		suite: suiteEnv{
			qemu:       firstNonEmpty(get("QEMU"), "qemu-system-x86_64"),
			swtpm:      firstNonEmpty(get("SWTPM"), "swtpm"),
			ovmfCode:   get("OVMF_CODE"),
			ovmfVars:   get("OVMF_VARS"),
			accel:      firstNonEmpty(get("E2E_IMAGE_ACCEL"), "kvm:tcg"),
			out:        get("E2E_IMAGE_OUT"),
			cryptosctl: get("CRYPTOSCTL"),
		},
		iso:     get("E2E_ISO"),
		uki:     get("E2E_ISO_UKI"),
		nextUKI: get("E2E_ISO_NEXT_UKI"),
		cert:    get("E2E_ISO_CERT"),
		ver:     get("E2E_ISO_VERSION"),
		nextVer: get("E2E_ISO_NEXT_VERSION"),
		tap:     get("E2E_ISO_TAP"),
	}
	for k, v := range map[string]string{
		"OVMF_CODE": e.suite.ovmfCode, "OVMF_VARS": e.suite.ovmfVars, "E2E_IMAGE_OUT": e.suite.out,
		"CRYPTOSCTL": e.suite.cryptosctl, "E2E_ISO": e.iso, "E2E_ISO_UKI": e.uki, "E2E_ISO_NEXT_UKI": e.nextUKI,
		"E2E_ISO_CERT": e.cert, "E2E_ISO_VERSION": e.ver, "E2E_ISO_NEXT_VERSION": e.nextVer,
	} {
		if v == "" {
			t.Fatalf("signed-ISO test: %s must be set (run it through test/image/run-iso.sh)", k)
		}
	}
	return e
}

type isoState struct {
	env      isoEnv
	admin    admin
	adminPEM string
	node     *vm
}

func TestSignedISO(t *testing.T) {
	ie := loadISOEnv(t)
	s := &suite{t: t, env: ie.suite, passed: map[string]bool{}, title: "Signed ISO (cryptosctl image sign on an unsigned ISO, install from it, upgrade)"}
	t.Cleanup(s.writeSummary)

	certPEM, adminKeyPEM, _ := generateBootstrapAdmin(t)
	a := admin{cert: filepath.Join(ie.suite.out, "admin.crt"), key: filepath.Join(ie.suite.out, "admin.key")}
	writeFile(t, a.cert, certPEM)
	writeFile(t, a.key, adminKeyPEM)
	st := &isoState{env: ie, admin: a, adminPEM: string(certPEM)}

	const (
		verify  = "signed ISO: the EFI boot image's BOOTX64.EFI and /cryptos.uki are the signed UKI, sbverify --cert passes on both, the .sig verifies"
		install = "signed ISO: boots on a blank disk, installs a nodeid Root over the maintenance API, the disk boots the signed UKI and serves image upgrades"
		upgrade = "signed ISO: a second ISO's UKI, signed with the same key, stages, activates and boots"
		noDHCP  = "signed ISO: on a link with no DHCP server, the node booted from the ISO serves the maintenance API on its self-assigned link-local address"
	)
	s.step(verify, nil, func(t *testing.T) { isoStepVerify(t, st) })
	s.step(install, []string{verify}, func(t *testing.T) { isoStepInstall(t, s, st) })
	s.step(upgrade, []string{install}, func(t *testing.T) { isoStepUpgrade(t, st) })

	if st.node != nil {
		st.node.stop()
	}
	s.step(noDHCP, []string{verify}, func(t *testing.T) { isoStepLinkLocal(t, s, st) })
}

// linkLocalFromMAC is the RFC 3927 address a CryptOS node gives itself on a
// NIC with this MAC when no DHCP server answers: the first two bytes of the
// MAC's SHA-256, taken into 169.254.1.0 to 169.254.254.255.
func linkLocalFromMAC(t *testing.T, s string) string {
	t.Helper()
	mac, err := net.ParseMAC(s)
	if err != nil {
		t.Fatalf("parse MAC %s: %v", s, err)
	}
	sum := sha256.Sum256(mac)
	n := binary.BigEndian.Uint16(sum[:2]) % (254 * 256)
	return fmt.Sprintf("169.254.%d.%d", 1+n/256, n%256)
}

// isoStepLinkLocal boots the signed ISO on a blank disk with its NIC on a
// host tap device that has no DHCP server behind it. The kernel's ip=dhcp
// gets no answer, the node assigns itself the link-local address its MAC
// gives, and the host, on its own 169.254.0.0/16 address on that link,
// reaches the maintenance API there the way a laptop on a direct cable does.
func isoStepLinkLocal(t *testing.T, s *suite, st *isoState) {
	if st.env.tap == "" {
		t.Skip("no tap link with no DHCP server (E2E_ISO_TAP); test/image/run-iso.sh makes one when it can use sudo")
	}
	dir := filepath.Join(s.env.out, "vm-iso-linklocal")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("vm dir: %v", err)
	}
	v := &vm{
		s: s, name: "iso-linklocal", dir: dir, uuid: "564d0007-0000-0000-0000-00000000e2e7",
		tap: st.env.tap, mac: isoLinkLocalMAC, admin: st.admin, iso: st.env.iso,
	}
	v.disk = filepath.Join(dir, "disk.img")
	v.cover = filepath.Join(dir, "cover.img")
	for _, d := range []struct{ path, size string }{{v.disk, "2G"}, {v.cover, "128M"}} {
		if out, err := exec.Command("truncate", "-s", d.size, d.path).CombinedOutput(); err != nil {
			t.Fatalf("create %s: %v\n%s", d.path, err, out)
		}
	}
	mustRun(t, "mformat", "-i", v.cover, "-v", "COVER", "::")
	v.vars = filepath.Join(dir, "OVMF_VARS.fd")
	copyFile(t, s.env.ovmfVars, v.vars)

	// The kernel's ip=dhcp tries for a while before it gives up, and only
	// then does the node assign its link-local address.
	limit := 6 * time.Minute
	if !strings.HasPrefix(s.env.accel, "kvm") {
		limit = 20 * time.Minute
	}
	addr := linkLocalFromMAC(t, isoLinkLocalMAC)
	v.start(t)
	defer v.stop()
	var status string
	eventually(t, "the maintenance API on the node's link-local address "+addr, limit, func() (bool, string) {
		out, err := run(t, "", s.env.cryptosctl, "--endpoint", addr+":443", "--insecure", "status")
		if err != nil {
			return false, out + "\n" + lastLines(v.serial.String(), 20)
		}
		status = out
		return true, ""
	})
	t.Logf("status on %s:\n%s", addr, status)
	note(t, "no DHCP server: the node took "+addr+" from its MAC and served the maintenance API there")
}

// isoStepVerify takes both copies of the UKI out of the signed ISO with
// tools that share nothing with cryptosctl, and checks each is the signed
// UKI written beside the ISO and carries a valid signature by the key.
func isoStepVerify(t *testing.T, st *isoState) {
	dir := t.TempDir()
	efiboot := filepath.Join(dir, "efiboot.img")
	mustRun(t, "xorriso", "-osirrox", "on", "-indev", st.env.iso,
		"-extract", "/cryptos.uki", filepath.Join(dir, "cryptos.uki"),
		"-extract", "/efiboot.img", efiboot)
	mustRun(t, "mcopy", "-n", "-i", efiboot, "::EFI/BOOT/BOOTX64.EFI", filepath.Join(dir, "BOOTX64.EFI"))

	want, err := os.ReadFile(st.env.uki)
	if err != nil {
		t.Fatalf("read the signed UKI: %v", err)
	}
	for _, name := range []string{"BOOTX64.EFI", "cryptos.uki"} {
		p := filepath.Join(dir, name)
		got, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s from the ISO: %v", name, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s in the ISO (%d bytes) is not the signed UKI written beside it (%d bytes)", name, len(got), len(want))
		}
		if out := mustRun(t, "sbverify", "--cert", st.env.cert, p); !strings.Contains(out, "Signature verification OK") {
			t.Fatalf("sbverify --cert %s %s:\n%s", st.env.cert, name, out)
		}
	}

	certPEM, err := os.ReadFile(st.env.cert)
	if err != nil {
		t.Fatalf("read the signing certificate: %v", err)
	}
	pub, ok := parsePEMCerts(t, certPEM)[0].PublicKey.(*rsa.PublicKey)
	if !ok {
		t.Fatal("the signing certificate does not hold an RSA key")
	}
	for _, uki := range []string{st.env.uki, st.env.nextUKI} {
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
			t.Fatalf("%s.sig does not verify against the signing certificate: %v", filepath.Base(uki), err)
		}
	}
	note(t, "xorriso and mcopy extracted BOOTX64.EFI and /cryptos.uki: both are the signed UKI and pass sbverify; both .sig files verify")
}

// isoStepInstall boots the signed ISO on a blank disk. With no state
// partition the node serves the maintenance API on its DHCP address; the
// install config names the disk, the node installs itself from the ISO,
// reboots, and the firmware boots the disk.
func isoStepInstall(t *testing.T, s *suite, st *isoState) {
	dir := filepath.Join(s.env.out, "vm-iso")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("vm dir: %v", err)
	}
	cfg := rootYAML(st.adminPEM, "e2e-iso")
	writeFile(t, filepath.Join(dir, "machine.yaml"), []byte(cfg))
	installCfg := filepath.Join(dir, "install.yaml")
	writeFile(t, installCfg, []byte(cfg+"install:\n  disk: "+isoInstallDisk+"\n"))

	v := &vm{
		s: s, name: "iso", dir: dir, uuid: "564d0006-0000-0000-0000-00000000e2e6", mgmtPort: isoMgmtPort,
		forwards: []string{"hostfwd=tcp:127.0.0.1:" + isoMaintPort + "-" + isoMaintAddr + ":443"},
		admin:    st.admin, iso: st.env.iso,
	}
	v.disk = filepath.Join(dir, "disk.img")
	v.cover = filepath.Join(dir, "cover.img")
	for _, d := range []struct{ path, size string }{{v.disk, "2G"}, {v.cover, "128M"}} {
		if out, err := exec.Command("truncate", "-s", d.size, d.path).CombinedOutput(); err != nil {
			t.Fatalf("create %s: %v\n%s", d.path, err, out)
		}
	}
	mustRun(t, "mformat", "-i", v.cover, "-v", "COVER", "::")
	v.vars = filepath.Join(dir, "OVMF_VARS.fd")
	copyFile(t, s.env.ovmfVars, v.vars)
	st.node = v

	limit := 3 * time.Minute
	if !strings.HasPrefix(s.env.accel, "kvm") {
		limit = 15 * time.Minute
	}
	v.start(t)
	maint := []string{"--endpoint", "127.0.0.1:" + isoMaintPort, "--insecure"}
	eventually(t, "the maintenance API of the node booted from the ISO", limit, func() (bool, string) {
		out, err := run(t, "", s.env.cryptosctl, append(maint, "status")...)
		if err != nil {
			return false, out + "\n" + lastLines(v.serial.String(), 20)
		}
		return true, ""
	})
	installed := time.Now()
	out := mustRun(t, s.env.cryptosctl, append(maint, "config", "apply", "-f", installCfg)...)
	t.Logf("config apply in maintenance mode:\n%s", out)
	v.waitUp(t, -1, installed, "install from the ISO and first boot from the disk")

	out = v.mustCtl(t, "ceremony", "start", "--config", filepath.Join(dir, "machine.yaml"))
	if !strings.Contains(out, "COMPLETE") {
		t.Fatalf("ceremony did not complete:\n%s", out)
	}
	v.trustCA(t)
	// The ISO's UKI carries no build-time anchor, so an answer here means
	// the sign-time anchor reached init on the installed disk.
	status, err := v.ctl("", "image", "status")
	if err != nil {
		t.Fatalf("image status on the installed node: %v\n%s", err, status)
	}
	if got := runningVersion(status); got != st.env.ver {
		t.Fatalf("image status: running %q, want %q:\n%s", got, st.env.ver, status)
	}
	signed, err := os.ReadFile(st.env.uki)
	if err != nil {
		t.Fatalf("read the signed UKI: %v", err)
	}
	sum := sha256.Sum256(signed)
	if !strings.Contains(status, hex.EncodeToString(sum[:])) {
		t.Fatalf("the installed node does not run the signed UKI from the ISO (sha256 %x):\n%s", sum, status)
	}
	note(t, "installed "+st.env.ver+" from the signed ISO; the disk runs the signed UKI and image status answers")
}

// isoStepUpgrade stages the UKI that `image sign` wrote beside the second
// signed ISO, with its .sig, onto the node installed from the first.
func isoStepUpgrade(t *testing.T, st *isoState) {
	v := st.node
	idBefore := v.mustCtl(t, "identity", "show", "-o", "pem")
	out := v.mustCtl(t, "image", "stage", "--image", st.env.nextUKI, "--signature", st.env.nextUKI+".sig")
	t.Logf("image stage:\n%s", out)
	if staged := v.mustCtl(t, "image", "status"); !strings.Contains(staged, "Reboot pending:   yes") {
		t.Fatalf("after staging, want a reboot pending:\n%s", staged)
	}
	bootsBefore := bootCount(v.status(t))
	started := time.Now()
	v.mustCtl(t, "image", "activate", "--confirm", suiteRootCN)
	v.waitUp(t, bootsBefore, started, "upgrade to the second signed image")
	after := v.mustCtl(t, "image", "status")
	if got := runningVersion(after); got != st.env.nextVer || !strings.Contains(after, "Reboot pending:   no") {
		t.Fatalf("after the upgrade, want %s running and nothing pending:\n%s", st.env.nextVer, after)
	}
	if id := v.mustCtl(t, "identity", "show", "-o", "pem"); id != idBefore {
		t.Fatal("the identity changed across the upgrade")
	}
	note(t, st.env.nextVer+" staged, activated and running with the same identity")
}
