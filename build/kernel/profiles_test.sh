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

if [ "$fail" = 0 ]; then
  echo "profiles_test: PASS"
  exit 0
fi
echo "profiles_test: FAIL"
exit 1
