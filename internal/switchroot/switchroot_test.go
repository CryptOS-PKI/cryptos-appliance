package switchroot

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
	"encoding/base64"
	"errors"
	"io/fs"
	"slices"
	"strings"
	"testing"
)

type mockSystem struct {
	calls   []string
	loopDev string
	// failts simulate a failure at a given call name.
	failOn   string
	mkdirErr error
	// files backs ReadFile; a missing key reads as fs.ErrNotExist.
	files   map[string][]byte
	readErr error
	// execEnv is the environment Exec was called with.
	execEnv []string
}

func (m *mockSystem) record(s string) { m.calls = append(m.calls, s) }

func (m *mockSystem) Mkdir(path string, _ uint32) error {
	m.record("mkdir " + path)
	if m.mkdirErr != nil {
		return m.mkdirErr
	}
	return nil
}

func (m *mockSystem) Mount(source, target, fstype string, flags uintptr, _ string) error {
	m.record("mount " + source + " " + target + " " + fstype)
	if m.failOn == "mount:"+target {
		return errors.New("boom")
	}
	return nil
}

func (m *mockSystem) AttachLoop(backingFile string) (string, error) {
	m.record("attachloop " + backingFile)
	if m.failOn == "attachloop" {
		return "", errors.New("boom")
	}
	return m.loopDev, nil
}

func (m *mockSystem) Chdir(dir string) error  { m.record("chdir " + dir); return nil }
func (m *mockSystem) Chroot(dir string) error { m.record("chroot " + dir); return nil }

func (m *mockSystem) ReadFile(path string) ([]byte, error) {
	if m.readErr != nil {
		return nil, m.readErr
	}
	b, ok := m.files[path]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return b, nil
}

func (m *mockSystem) Exec(argv0 string, _, envv []string) error {
	m.record("exec " + argv0)
	m.execEnv = envv
	if m.failOn == "exec" {
		return errors.New("boom")
	}
	// A real Exec never returns; the mock returns nil and Run reports that
	// as an error, which lets us assert exec was reached.
	return nil
}

func TestRun_Sequence(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0"}
	err := Run(m, nil)
	// Exec "succeeds" in the mock, which Run treats as an error.
	if err == nil || !strings.Contains(err.Error(), "exec returned") {
		t.Fatalf("expected exec-returned error, got %v", err)
	}

	want := []string{
		"mkdir /dev",
		"mount devtmpfs /dev devtmpfs",
		"mkdir /sysroot",
		"attachloop /rootfs.squashfs",
		"mount /dev/loop0 /sysroot squashfs",
		"chdir /sysroot",
		"mount . / ",
		"chroot .",
		"chdir /",
		"exec /init",
	}
	got := strings.Join(m.calls, "|")
	if got != strings.Join(want, "|") {
		t.Errorf("call sequence:\n got %v\nwant %v", m.calls, want)
	}
}

func TestRun_LoopFailureStopsBeforePivot(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0", failOn: "attachloop"}
	if err := Run(m, nil); err == nil {
		t.Fatal("expected error when AttachLoop fails")
	}
	for _, c := range m.calls {
		if strings.HasPrefix(c, "chroot") || strings.HasPrefix(c, "exec") {
			t.Errorf("pivot step %q ran despite loop failure", c)
		}
	}
}

func TestRun_SquashFSMountFailure(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0", failOn: "mount:/sysroot"}
	if err := Run(m, nil); err == nil {
		t.Fatal("expected error when the SquashFS mount fails")
	}
}

func TestRun_ExistingDirsAreOK(t *testing.T) {
	// Mkdir returning fs.ErrExist must not abort the pivot.
	m := &mockSystem{loopDev: "/dev/loop0", mkdirErr: fs.ErrExist}
	if err := Run(m, nil); err == nil || !strings.Contains(err.Error(), "exec returned") {
		t.Fatalf("ErrExist on mkdir should be tolerated, got %v", err)
	}
}

func anchorValues(env []string) []string {
	var vals []string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, AnchorEnv+"="); ok {
			vals = append(vals, v)
		} else if kv == AnchorEnv {
			vals = append(vals, "")
		}
	}
	return vals
}

func TestRun_AnchorFilePassedToInit(t *testing.T) {
	der := []byte{0x30, 0x82, 0x01, 0x0a, 0xde, 0xad, 0xbe, 0xef}
	m := &mockSystem{loopDev: "/dev/loop0", files: map[string][]byte{AnchorPath: der}}
	_ = Run(m, []string{"HOME=/", "TERM=linux"})

	got := anchorValues(m.execEnv)
	want := base64.StdEncoding.EncodeToString(der)
	if len(got) != 1 || got[0] != want {
		t.Fatalf("%s in init env = %v, want exactly [%s]", AnchorEnv, got, want)
	}
	for _, kv := range []string{"HOME=/", "TERM=linux"} {
		if !slices.Contains(m.execEnv, kv) {
			t.Errorf("init env lost %q: %v", kv, m.execEnv)
		}
	}
}

func TestRun_NoAnchorFileLeavesVariableAbsent(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0"}
	_ = Run(m, []string{"HOME=/"})

	if got := anchorValues(m.execEnv); len(got) != 0 {
		t.Fatalf("%s set without an anchor file: %v", AnchorEnv, got)
	}
	if !slices.Contains(m.execEnv, "HOME=/") {
		t.Errorf("init env lost HOME: %v", m.execEnv)
	}
}

func TestRun_InheritedAnchorIsStripped(t *testing.T) {
	inherited := []string{AnchorEnv + "=bm90LXRydXN0ZWQ=", AnchorEnv, "HOME=/"}

	t.Run("no anchor file", func(t *testing.T) {
		m := &mockSystem{loopDev: "/dev/loop0"}
		_ = Run(m, inherited)
		if got := anchorValues(m.execEnv); len(got) != 0 {
			t.Fatalf("inherited %s reached init: %v", AnchorEnv, got)
		}
	})

	t.Run("anchor file replaces it", func(t *testing.T) {
		der := []byte{0x30, 0x01, 0x02}
		m := &mockSystem{loopDev: "/dev/loop0", files: map[string][]byte{AnchorPath: der}}
		_ = Run(m, inherited)
		got := anchorValues(m.execEnv)
		want := base64.StdEncoding.EncodeToString(der)
		if len(got) != 1 || got[0] != want {
			t.Fatalf("%s in init env = %v, want exactly [%s]", AnchorEnv, got, want)
		}
	})
}

func TestRun_EmptyAnchorFileIsIgnored(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0", files: map[string][]byte{AnchorPath: {}}}
	_ = Run(m, nil)
	if got := anchorValues(m.execEnv); len(got) != 0 {
		t.Fatalf("%s set from an empty anchor file: %v", AnchorEnv, got)
	}
}

func TestRun_AnchorReadErrorStopsBeforePivot(t *testing.T) {
	m := &mockSystem{loopDev: "/dev/loop0", readErr: errors.New("io error")}
	if err := Run(m, nil); err == nil || !strings.Contains(err.Error(), AnchorPath) {
		t.Fatalf("expected an anchor read error, got %v", err)
	}
	if len(m.calls) != 0 {
		t.Errorf("steps ran after the anchor read failed: %v", m.calls)
	}
}
