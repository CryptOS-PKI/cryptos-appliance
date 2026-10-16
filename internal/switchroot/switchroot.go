// Package switchroot is the shim init for the SquashFS-root boot path. The
// UKI carries a tiny initramfs whose /init is this shim plus the read-only
// SquashFS rootfs image. The shim loop-mounts the SquashFS and switch_roots
// into it, so the real PID 1 (the Go init baked into the SquashFS) runs from
// an immutable, RAM-resident read-only root.
//
// The shim mounts only /dev (needed to set up the loop device); it leaves
// /proc, /sys, /run, and /tmp for the real init's EarlyMounts so the two
// never fight over the same mount.
//
// The shim also carries a sign-time upgrade anchor across the pivot. The
// signing step appends /upgrade-anchor.der to the UKI's measured .initrd;
// the initramfs is out of reach once the real init runs, so the shim reads
// the file and hands it to init as CRYPTOS_UPGRADE_ANCHOR.
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
	"fmt"
	"io/fs"
	"strings"
)

const (
	// SquashFSPath is where the SquashFS image sits in the shim initramfs.
	SquashFSPath = "/rootfs.squashfs"
	// NewRoot is the mountpoint the SquashFS is mounted at before pivoting.
	NewRoot = "/sysroot"
	// InitPath is the real PID 1 inside the SquashFS, exec'd after pivot.
	InitPath = "/init"
	// AnchorPath is the sign-time upgrade anchor (a DER certificate) in the
	// shim initramfs, present only when the signing step added one.
	AnchorPath = "/upgrade-anchor.der"
	// AnchorEnv is the variable the real init reads the anchor from, as
	// standard base64 of the DER.
	AnchorEnv = "CRYPTOS_UPGRADE_ANCHOR"

	// msRDONLY / msMOVE are the stable MS_* flag values used here (defined
	// locally so the sequence logic stays OS-independent and unit-testable).
	msRDONLY uintptr = 1 << 0 // MS_RDONLY
	msMOVE   uintptr = 1 << 13
)

// System is the set of OS operations the pivot needs, injected so the
// sequence can be unit-tested without touching real mounts or loop devices.
type System interface {
	Mkdir(path string, perm uint32) error
	Mount(source, target, fstype string, flags uintptr, data string) error
	// AttachLoop binds backingFile to a free loop device and returns its
	// path (e.g. /dev/loop0).
	AttachLoop(backingFile string) (string, error)
	Chdir(dir string) error
	Chroot(dir string) error
	// ReadFile returns the contents of path; a missing file is an error
	// matching fs.ErrNotExist.
	ReadFile(path string) ([]byte, error)
	// Exec replaces the current process image (execve); on success it does
	// not return.
	Exec(argv0 string, argv, envv []string) error
}

// Run performs the SquashFS-root pivot:
//
//  1. mount devtmpfs at /dev so the loop device can be set up;
//  2. loop-mount the SquashFS read-only at /sysroot;
//  3. switch_root into /sysroot and exec the real /init.
//
// Before the pivot it reads the sign-time anchor, if any, and execs init
// with it in AnchorEnv. Any inherited AnchorEnv is always dropped first:
// the kernel turns command-line key=value words into init's environment,
// and the command line is not trusted.
//
// On success Exec does not return; any return value is an error.
func Run(sys System, env []string) error {
	initEnv, err := anchorEnv(sys, env)
	if err != nil {
		return err
	}

	if err := sys.Mkdir("/dev", 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("switchroot: mkdir /dev: %w", err)
	}
	if err := sys.Mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755"); err != nil {
		return fmt.Errorf("switchroot: mount /dev: %w", err)
	}

	if err := sys.Mkdir(NewRoot, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("switchroot: mkdir %s: %w", NewRoot, err)
	}

	loop, err := sys.AttachLoop(SquashFSPath)
	if err != nil {
		return fmt.Errorf("switchroot: attach loop for %s: %w", SquashFSPath, err)
	}
	if err := sys.Mount(loop, NewRoot, "squashfs", msRDONLY, ""); err != nil {
		return fmt.Errorf("switchroot: mount %s on %s: %w", loop, NewRoot, err)
	}

	// switch_root: make NewRoot the new / and exec the real init there.
	if err := sys.Chdir(NewRoot); err != nil {
		return fmt.Errorf("switchroot: chdir %s: %w", NewRoot, err)
	}
	if err := sys.Mount(".", "/", "", msMOVE, ""); err != nil {
		return fmt.Errorf("switchroot: move mount to /: %w", err)
	}
	if err := sys.Chroot("."); err != nil {
		return fmt.Errorf("switchroot: chroot: %w", err)
	}
	if err := sys.Chdir("/"); err != nil {
		return fmt.Errorf("switchroot: chdir /: %w", err)
	}
	if err := sys.Exec(InitPath, []string{InitPath}, initEnv); err != nil {
		return fmt.Errorf("switchroot: exec %s: %w", InitPath, err)
	}
	return errors.New("switchroot: exec returned without error")
}

// anchorEnv returns env without any inherited AnchorEnv, plus AnchorEnv set
// from AnchorPath when that file exists and is not empty.
func anchorEnv(sys System, env []string) ([]string, error) {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if kv == AnchorEnv || strings.HasPrefix(kv, AnchorEnv+"=") {
			continue
		}
		out = append(out, kv)
	}

	der, err := sys.ReadFile(AnchorPath)
	if errors.Is(err, fs.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, fmt.Errorf("switchroot: read %s: %w", AnchorPath, err)
	}
	if len(der) == 0 {
		return out, nil
	}
	return append(out, AnchorEnv+"="+base64.StdEncoding.EncodeToString(der)), nil
}
