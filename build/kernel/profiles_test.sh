#!/usr/bin/env bash
# Unit test for the platform kernel profiles: each one stays additive, keeps
# every driver built in, and holds what its platform needs. build.sh checks
# that each option survives the kernel merge; this checks the option is asked
# for at all.
#
# Usage: build/kernel/profiles_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profiles="$here/profiles"
fail=0

want() {
  local profile="$1"
  shift
  local opt
  for opt in "$@"; do
    if ! grep -q "^CONFIG_$opt=y$" "$profiles/$profile.config" 2>/dev/null; then
      echo "FAIL $profile: CONFIG_$opt=y is missing"
      fail=1
    fi
  done
}

for f in "$profiles"/*.config; do
  name="$(basename "$f")"
  if grep -E '^CONFIG_[A-Z0-9_]+=m$' "$f"; then
    echo "FAIL $name: every driver is built in, the kernel has no modules"
    fail=1
  fi
  if grep -q '^CONFIG_MODULES=y' "$f"; then
    echo "FAIL $name turns modules on"
    fail=1
  fi
done

# Disk controllers, the CD a Proxmox VM boots from, and the guest channels.
want proxmox SCSI SCSI_VIRTIO BLK_DEV_SD BLK_DEV_NVME SATA_AHCI ATA_PIIX \
  BLK_DEV_SR ISO9660_FS E1000 E1000E VIRTIO_CONSOLE HW_RANDOM_VIRTIO \
  SERIO_I8042 KEYBOARD_ATKBD

# Common server storage and NICs, and the USB path a BMC's virtual media and a
# local keyboard use. No module loads later, so what is not here does not work.
want baremetal PCI_MSI BLK_DEV_NVME SATA_AHCI BLK_DEV_SD SCSI_MPT3SAS \
  MEGARAID_SAS SCSI_SMARTPQI SCSI_HPSA SCSI_AACRAID BLK_DEV_SR ISO9660_FS \
  USB_XHCI_HCD USB_EHCI_HCD USB_STORAGE USB_UAS USB_HID E1000E IGB IGC IXGBE \
  I40E ICE TIGON3 BNXT MLX4_EN MLX5_CORE_EN R8169

# A physical server gets no hypervisor drivers on top of the base.
for opt in VMWARE_PVSCSI VMXNET3 SCSI_VIRTIO VIRTIO_CONSOLE HW_RANDOM_VIRTIO; do
  if grep -q "^CONFIG_$opt=" "$profiles/baremetal.config" 2>/dev/null; then
    echo "FAIL baremetal: CONFIG_$opt is a guest driver"
    fail=1
  fi
done

if [ "$fail" = 0 ]; then
  echo "profiles_test: PASS"
  exit 0
fi
echo "profiles_test: FAIL"
exit 1
