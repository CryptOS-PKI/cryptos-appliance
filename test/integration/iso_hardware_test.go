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
	"strings"
	"testing"
)

func TestISOHardware(t *testing.T) {
	cases := []struct {
		platform, disk, installDisk, nic string
	}{
		{"vmware", "virtio-blk-pci,drive=disk,bootindex=1", "/dev/vda", "virtio-net-pci,netdev=n0"},
		{"proxmox", "scsi-hd,drive=disk,bus=scsi0.0,bootindex=1", "/dev/sda", "virtio-net-pci,netdev=n0"},
		{"baremetal", "nvme,drive=disk,serial=cryptos-nvme,bootindex=1", "/dev/nvme0n1", "e1000e,netdev=n0"},
	}
	for _, c := range cases {
		t.Run(c.platform, func(t *testing.T) {
			hw, err := isoHardware(c.platform)
			if err != nil {
				t.Fatal(err)
			}
			if hw.disk != c.disk || hw.installDisk != c.installDisk || hw.nic != c.nic {
				t.Fatalf("got disk %q at %q, NIC %q", hw.disk, hw.installDisk, hw.nic)
			}
		})
	}
	if _, err := isoHardware("no-such-platform"); err == nil {
		t.Fatal("an unknown platform must fail, not fall back to another's hardware")
	}
}

func TestISORootYAMLStateKey(t *testing.T) {
	got := isoRootYAML("cert", "n", "tpm")
	if !strings.Contains(got, "state_key: {mode: tpm}") || strings.Contains(got, "mode: nodeid") {
		t.Fatalf("the tpm config still names nodeid:\n%s", got)
	}
}

// QEMU resolves a device's bus when it reads the -device, so a controller has
// to come before the disk on it.
func TestStorageArgsPutControllersFirst(t *testing.T) {
	hw, err := isoHardware("proxmox")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(hw.storageArgs(), " ")
	if ctrl, disk := strings.Index(args, "virtio-scsi-pci"), strings.Index(args, "scsi-hd"); ctrl < 0 || disk < ctrl {
		t.Fatalf("the controller must precede the disk: %s", args)
	}
}
