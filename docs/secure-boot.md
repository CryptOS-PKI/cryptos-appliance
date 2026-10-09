# Secure Boot: build and sign with your own key

CryptOS does not ship a signing key, and it does not ask you to trust one. You
generate your own Secure Boot key, build the image with it, and enroll its
certificate on the machines you run. The same certificate becomes the node's
upgrade anchor, so the key that makes an image bootable is also the only key
that can replace it later.

> [!IMPORTANT]
> **Public release assets are unsigned, or a build recipe only.** Nothing the
> project publishes is signed by, carries, or trusts a key the project
> generated. A prebuilt image is for evaluation with Secure Boot off; it has no
> upgrade anchor, so a node installed from it cannot be upgraded in place. To
> run CryptOS for real, build it with your own key by following this guide.
> See [Unsigned builds and the release assets](#unsigned-builds-and-the-release-assets).

## What the key is used for

`build/uki/sign.sh` takes the key and certificate you hand it through
`SB_KEY` / `SB_CERT` and uses them three ways. They have to be the same key
and certificate for all three:

| Use | Done by | Checked by |
|---|---|---|
| Authenticode signature on the UKI | `sbsign` in `build/uki/sign.sh` | the machine's firmware, against Secure Boot `db` |
| Detached signature, `cryptos-<arch>.uki.sig` | `openssl dgst -sha256 -sign` in `build/uki/sign.sh` | the running node, at `cryptosctl image stage` |
| Upgrade anchor stamped into `/init` | `build/squashfs/build.sh`, when `SB_CERT` is set | the node, when it verifies the next image's `.sig` |

The anchor is compiled into the init binary as
`internal/release.CertificateDER`. It is never read from configuration or
disk, so an administrator cannot swap it at runtime. See
[`image-upgrade.md`](image-upgrade.md) for the upgrade path it protects.

## 1. Generate your signing key and certificate

Do this on the machine that will hold the key, ideally an offline or
dedicated build host. Either of the two methods below produces the same three
files:

| File | Encoding | Consumed by |
|---|---|---|
| `sb.key` | RSA private key, PEM | `SB_KEY` (`sbsign --key`, `openssl dgst -sign`) |
| `sb.crt` | certificate, PEM | `SB_CERT` (`sbsign --cert`, `sbverify`, the stamped anchor) |
| `sb.der` | certificate, raw DER | firmware `db` enrollment |

### With openssl

```bash
umask 077
mkdir -p ~/cryptos-sb && cd ~/cryptos-sb

openssl req -new -x509 -newkey rsa:2048 -sha256 -noenc -days 3650 \
  -subj "/O=Example Org/CN=Example Org Secure Boot Signing 2026" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout sb.key -out sb.crt

openssl x509 -in sb.crt -outform DER -out sb.der
```

> [!CAUTION]
> `-noenc` needs OpenSSL 3.0 or later; on 1.1.1 use `-nodes`. The key is written
> unencrypted because `sbsign` and `sign.sh` read it non-interactively; protect it
> with file permissions and storage instead (see "Key custody" below).

The extensions match what `cryptos-sbkey` writes: a self-signed certificate
with the code-signing extended key usage.

### With `cryptos-sbkey`

The repository's own generator does the same thing without openssl:

```bash
task build                     # produces bin/cryptos-sbkey
bin/cryptos-sbkey --out-dir ~/cryptos-sb --cn "Example Org Secure Boot Signing 2026"
```

Flags: `--out-dir`, `--cn`, `--days` (0, the default, means about 10 years),
`--bits` (`2048`, the default, or `4096`) and `--force` to overwrite existing
files. `sb.key` is written as PKCS#8 PEM with mode 0600.

### Key size

Use **RSA**. The anchor check refuses any other key type
(`internal/release`), and the detached signature is PKCS#1 v1.5 over SHA-256.

- **RSA-2048** is the UEFI-mandated baseline and loads on every firmware.
  Choose it unless you have a reason not to.
- **RSA-4096** works only on firmware that accepts RSA-4096 certificates in
  `db`. Swap `rsa:2048` for `rsa:4096` (or pass `--bits 4096`), and confirm
  the target firmware boots a test image before you depend on it. Firmware
  that rejects the key refuses to boot the image.

ECDSA is not an option here, even though CryptOS uses ECDSA for its CA keys:
support for ECDSA in `db` is inconsistent across firmware vendors, and the
anchor check expects RSA. This key signs boot images and nothing else.

### Validity

Give the certificate a long life: 10 years (`-days 3650`, or the
`cryptos-sbkey` default) is the recommended value. Expiry is not what limits
the key:

- The node does not enforce the anchor's validity dates. An expired anchor
  would otherwise block the one upgrade that could replace it.
- Most firmware, including EDK II/OVMF, has no trusted clock and does not
  enforce the dates on `db` certificates or image signatures either.

Changing the key is the expensive part (a fleet-wide `db` update and, without
the old key, a re-provision), so pick a lifetime that outlasts the nodes. Do
not copy the one-day validity the CI workflow uses; that key is thrown away
at the end of the run.

## 2. Decide: Secure Boot on or off

The detached signature and the stamped anchor work the same either way. What
changes is whether the firmware also checks the image at every boot.

| | Secure Boot **on**, your cert in `db` | Secure Boot **off** |
|---|---|---|
| Firmware refuses a tampered or foreign image at boot | yes | no |
| Upgrades must be signed by your key | yes | yes (stamped anchor) |
| Setup needed per machine | enroll `sb.der` in `db` | none |

> [!CAUTION]
> Decide **before installing a node**. With the default `STATEKEY=tpm`, the state
> partition key is sealed to PCR 7, which measures the Secure Boot state and the
> `db` contents. Turning Secure Boot on or off, or changing `db`, after the node
> is installed means the state key no longer unseals. The `STATEKEY=nodeid`
> variant does not use the TPM and is not affected.

## 3. Enroll the certificate (Secure Boot on)

Skip this section if you run with Secure Boot off.

UEFI keeps three authority levels: **PK** (owns the platform and signs KEK
updates), **KEK** (signs `db`/`dbx` updates) and **db** (certificates the
firmware loads images from). `dbx` is the revocation list. You only need to
**add your certificate to db**; the existing PK, KEK and vendor `db` entries can
stay.

### VMware vSphere / ESXi

A VM with EFI firmware and Secure Boot enabled starts with the Microsoft and
VMware certificates in `db`, which do not cover your image. You add yours from
the VM's own firmware setup, reading the certificate from a virtual CD. These
steps were checked on ESXi 8.0.3.

#### Build the certificate CD

The firmware's file browser reads only FAT file systems. On a CD it finds one
only as an El Torito boot image, so you put `sb.der` in a small FAT image and
make that image the CD's El Torito image. No extra virtual disk is needed.

> [!CAUTION]
> A plain ISO 9660 CD holding `sb.der` does not work: the firmware reports
> `No File System Found`. Build the CD as below.

Install the tools:

**Linux (Debian or Ubuntu; on Fedora use `sudo dnf install mtools xorriso`)**

```bash
sudo apt install mtools xorriso
```

**macOS (Homebrew)**

```bash
brew install mtools xorriso
```

Then, in the directory that holds `sb.der`, build `sb-enrol.iso`. The commands
are the same on Linux and macOS:

```bash
mkdir sb-enrol
mformat -i sb-enrol/sb-enrol.img -C -f 1440 -v SBCERT ::
mcopy -i sb-enrol/sb-enrol.img sb.der ::/cryptos-sb.der
xorriso -as mkisofs -o sb-enrol.iso -V SBCERT \
  -e sb-enrol.img -no-emul-boot sb-enrol
```

`mformat -C -f 1440` creates a 1.44 MB FAT12 image, `mcopy` puts the
certificate in it, and `xorriso -e ... -no-emul-boot` makes that image the
CD's El Torito boot image.

> [!CAUTION]
> The file on the image must end in a lowercase `.der` (or `.cer`). A name
> stored only as an upper-case 8.3 name, such as `SB.DER`, is refused with
> `Unsupported file type`. A name longer than eight characters, such as
> `cryptos-sb.der`, keeps its lowercase long name on the FAT image.

Check the result before you upload it:

```bash
mdir -i sb-enrol/sb-enrol.img ::/
xorriso -indev sb-enrol.iso -report_el_torito plain
```

> [!TIP]
> `mdir` lists `cryptos-sb.der` in lowercase at the end of its line, and the
> xorriso report has an `El Torito img path` line naming `/sb-enrol.img`.

#### Enroll the certificate

1. Upload `sb-enrol.iso` to a datastore the host can read.
2. Power the VM off. Under **VM Options > Advanced > Configuration
   Parameters**, add `uefi.allowAuthBypass` = `TRUE`. This lets the VM's
   firmware setup accept a `db` entry that is not signed by a KEK.
3. Under **VM Options > Boot Options**, check that the firmware is **EFI** and
   turn **Secure Boot** on.
4. Attach `sb-enrol.iso` to the VM's CD/DVD drive with **Connect At Power On**
   ticked.
5. Under **VM Options > Boot Options**, tick **Force EFI setup**, then power
   the VM on. It stops in the **Boot Manager**.
6. Choose **Enter setup**, then **Secure Boot Configuration > Custom Secure
   Boot Options > DB Options > Enroll DB > Enroll DB Using File**.
7. In the **File Explorer**, pick the volume labelled `SBCERT` (its path ends
   in `CDROM(...)`), then `cryptos-sb.der`.
8. Choose **Commit Changes and Exit**.
9. To check, open **DB Options > Delete DB**. Your certificate's common name is
   listed next to the Microsoft and VMware entries. Leave with **Esc** without
   ticking anything, then shut the VM down from the Boot Manager (**Shut down
   the system**).

With govc, steps 2 to 5 are:

```bash
govc vm.change -vm cryptos-node -e uefi.allowAuthBypass=TRUE
govc device.boot -vm cryptos-node -firmware efi -secure=true
govc device.cdrom.insert -vm cryptos-node -ds datastore1 ISO/sb-enrol.iso
govc device.boot -vm cryptos-node -setup
govc vm.power -on cryptos-node
```

If the CD/DVD drive is not set to connect at power on, `govc device.ls -vm
cryptos-node` names it (for example `cdrom-3000`), and `govc device.connect -vm
cryptos-node cdrom-3000` connects it.

> [!WARNING]
> Remove `uefi.allowAuthBypass` as soon as the certificate is in `db`. While it
> is set, anyone with access to the VM's console can change `db` from firmware
> setup without a KEK signature.

10. With the VM powered off, remove `uefi.allowAuthBypass` (with govc:
    `govc vm.change -vm cryptos-node -e uefi.allowAuthBypass=`), detach
    `sb-enrol.iso`, and confirm **Secure Boot** is still on under **VM Options
    > Boot Options**.

> [!IMPORTANT]
> Do this before the first boot of the CryptOS installer image, for the reason
> given in step 2 above.

### Bare metal: firmware setup UI

1. Copy `sb.der` to a FAT32 USB stick.
2. Reboot into firmware setup, then Security > Secure Boot.
3. Put Secure Boot in **Setup Mode** or **Custom Mode** (vendor wording
   varies).
4. Choose **Enroll key / Add to db / Append signature** and select `sb.der`.
5. Save, return Secure Boot to **User Mode** / **Enabled**, reboot.

Most enterprise firmware accepts a raw DER (`.der` / `.cer`) file here.

### Bare metal: `sbctl` from a Linux live environment

CryptOS has no shell, so run this from a live Linux USB on the target, with the
firmware in Setup Mode:

> [!CAUTION]
> Drop `--append` only if you mean to replace the platform keys entirely.

```bash
sbctl status                                  # confirm Setup Mode
sbctl import-keys --db-cert ./sb.der          # add your cert to db
sbctl enroll-keys --append                    # --append keeps the existing keys
```

### Scripted or air-gapped: `efitools`

If you own PK and KEK, build a signed `db` update:

```bash
cert-to-efi-sig-list -g "$(uuidgen)" sb.der sb.esl
sign-efi-sig-list -k KEK.key -c KEK.crt db sb.esl sb.auth
# Apply sb.auth through the firmware's "update db" path or efi-updatevar.
```

## 4. Build the image with your key

The image build runs on a Linux host; see [`build/README.md`](../build/README.md)
for the toolchain. Pass the key and certificate as environment variables, with
absolute paths:

```bash
export SB_KEY="$HOME/cryptos-sb/sb.key"
export SB_CERT="$HOME/cryptos-sb/sb.crt"

task image PLATFORM=vmware STATEKEY=nodeid
```

`task image` builds the kernel, the static tools and the rootfs, assembles the
UKI and signs it. To also wrap it in a bootable ISO, run `task iso` instead; it
runs `task image` first:

```bash
task iso PLATFORM=vmware STATEKEY=nodeid
```

Drop `STATEKEY=nodeid` (or set `STATEKEY=tpm`) for the TPM-backed image; see
[`build/README.md`](../build/README.md#statekey-the-tpm-less-nodeid-variant)
for when `nodeid` is appropriate.

> [!IMPORTANT]
> **Keep `SB_CERT` set for the whole run.** The certificate is read twice, at
> different steps:
>
> - `rootfs:build` stamps it into `/init` as the upgrade anchor, if it is set.
> - `uki:sign` signs the finished UKI with `SB_KEY` / `SB_CERT`, and fails if
>   either is missing.
>
> Running the steps separately with `SB_CERT` unset during `rootfs:build` gives
> you a correctly signed image with **no** anchor: it boots, but a node installed
> from it serves the image upgrade RPCs as `Unimplemented` and can only be
> replaced by a reinstall. Exporting both variables once, as above, avoids that.

Outputs in `build/out/`:

| File | What it is |
|---|---|
| `cryptos-amd64.uki.unsigned` | the assembled UKI before signing |
| `cryptos-amd64.uki` | the signed UKI (anchor inside, Authenticode signature on it) |
| `cryptos-amd64.uki.sig` | the detached signature `image stage` checks |
| `cryptos-amd64-vmware-nodeid-<build>.iso` | the installer ISO (`task iso` only; `-nodeid` is omitted for `STATEKEY=tpm`; `<build>` is the git-describe build tag from `build/ci/artifact-name.sh`) |

## 5. Verify the build

`sign.sh` already runs both checks below and fails the build if either fails.
Run them yourself before you ship an image to a node.

The Authenticode signature is from your certificate:

```bash
sbverify --cert "$SB_CERT" build/out/cryptos-amd64.uki
sbverify --list build/out/cryptos-amd64.uki     # shows the signer subject
```

The detached signature verifies against the certificate (not just the key):

```bash
openssl dgst -sha256 \
  -verify <(openssl x509 -in "$SB_CERT" -pubkey -noout) \
  -signature build/out/cryptos-amd64.uki.sig \
  build/out/cryptos-amd64.uki
```

The anchor was stamped. The rootfs tree stays under `build/.work/` after the
build, and the anchor is the certificate's DER in base64:

```bash
grep -q -a -F "$(openssl x509 -in "$SB_CERT" -outform DER | base64 -w0)" \
  build/.work/rootfs-amd64/init && echo "anchor stamped"
```

> [!TIP]
> Expected output: `anchor stamped`.
> No output means the build carries no anchor.

On the target, with Secure Boot on, the machine should boot the image. If the
firmware refuses it, your certificate is not in `db`, or the image was signed
with a different key.

## 6. Upgrade with the same key

A node accepts a new image only if its `.sig` verifies against the anchor the
**running** image carries. Build every later version with the same `SB_KEY`
and `SB_CERT`, then stage and activate it as described in
[`image-upgrade.md`](image-upgrade.md):

> [!NOTE]
> `cryptosctl` runs on Linux and macOS today. A Windows build is coming.

```bash
cryptosctl --endpoint pki-root.example.org:443 image stage \
  --image build/out/cryptos-amd64.uki
```

The signature is read from `<image>.sig` unless `--signature` names another
file. An image signed by any other key is refused before anything is written
to the ESP.

## Unsigned builds and the release assets

`task image:unsigned` runs the same chain as `task image` but stops at
`uki:assemble`, and `task iso:unsigned` wraps that UKI in an ISO. They never
sign, and they clear `SB_CERT` for `rootfs:build`, so no anchor is stamped even
if `SB_KEY` and `SB_CERT` are exported in your shell:

```bash
task iso:unsigned PLATFORM=vmware STATEKEY=nodeid
```

| File | What it is |
|---|---|
| `cryptos-amd64.uki.unsigned` | the UKI, no Authenticode signature, no anchor |
| `cryptos-amd64-vmware-nodeid-unsigned-<build>.iso` | the installer ISO around it (`-nodeid` is omitted for `STATEKEY=tpm`; `<build>` is the git-describe build tag from `build/ci/artifact-name.sh`) |

This is how the public release assets are built. On a `v*` tag, CI runs
`task iso:unsigned` for `STATEKEY=tpm` and `STATEKEY=nodeid` with no Secure
Boot variables set, and attaches the UKIs (renamed
`cryptos-amd64-vmware[-nodeid]-<build>.uki.unsigned`), the ISOs, `cryptosctl`
for linux and darwin on amd64 and arm64 (each also named with `<build>`), a
`build-manifest.json` build record (the full and short commit, dirty state,
version and build tag), and a `SHA256SUMS`. The per-run key the CI smoke build
uses on `main` signs and anchors only images that are thrown away with the
run; none of them is uploaded.

Check that a build carries no anchor with the grep from step 5 against your own
certificate, or, without one, by looking for any base64 X.509 certificate in
`/init`:

```bash
grep -q -a -E 'MII[A-Za-z0-9+/]{400,}' build/.work/rootfs-amd64/init \
  && echo "anchor present" || echo "no anchor"
sbverify --list build/out/cryptos-amd64.uki.unsigned   # "No signature table present"
```

> [!IMPORTANT]
> Signing an unsigned UKI afterwards (`task uki:sign` with your key) makes it
> bootable with Secure Boot on, but it still has no anchor: the anchor is compiled
> into `/init` during `rootfs:build`, before the UKI exists. For a node you want
> to upgrade in place, build from source with `SB_CERT` set as in step 4.

## Key custody

The key is the only thing that can produce an image your nodes will accept.

> [!CAUTION]
> - **Losing the key means re-provisioning to change anchors.** A node checks the
>   next image against the anchor compiled into the image it is running, and
>   nothing on the node can replace that anchor. Without the key you cannot sign
>   an image it will stage, so the only way onto a new key is a reinstall, which
>   reformats the state partition and destroys the CA key.
> - **A leaked key lets anyone with admin access to a node install an image of
>   their choosing**, and, with Secure Boot on, boot it on any machine that
>   trusts your certificate. Treat it like a CA key.

- Keep it offline when you are not building: an encrypted backup in at least
  two places, and the working copy on a build host you control, readable only
  by the account that runs the build.
- Never commit it, never put it in CI secrets for a public repository, and do
  not reuse it for anything else.

## Rotation

> [!CAUTION]
> On a `STATEKEY=tpm` node, only steps 1 and 2 below are safe without a
> re-provision. See the caution after step 2 for what steps 3 through 5 cost
> on that mode, and what a re-provision there actually loses.

Rotation does not need a reinstall. It needs one extra image, built so its
*compiled-in anchor* moves to the new key before anything on the machine
checks the new key's Authenticode signature. Call that extra image the
**bridge**: it is signed, Authenticode and detached signature both, with the
key already in every machine's `db`, so it stages and boots exactly like any
other upgrade, with no firmware work first. Its anchor, though, is the new
certificate -- so once it is running, the next image the node will accept has
to carry the new key's detached signature.

Work through it with two key pairs: the one already in the fleet
(`sb-2026.key` / `sb-2026.crt`, already in `db`, already the running image's
anchor) and the one you are rotating to (`sb-2027.key` / `sb-2027.crt` /
`sb-2027.der`).

### 1. Build the bridge

`rootfs:build` stamps whatever `SB_CERT` is set to as the anchor;
`uki:sign` signs the UKI and the detached signature with `SB_KEY` / `SB_CERT`.
Run them as separate `task` invocations so the two can disagree -- one `task
image` run cannot do this, since it uses the same environment throughout.
`kernel:build` still needs the fleet's `PLATFORM` (it selects that platform's
drivers; nothing about rotation changes that):

```bash
export SB_CERT="$HOME/cryptos-sb/sb-2027.crt"   # the new cert becomes the anchor
task kernel:build PLATFORM=vmware               # match the fleet's platform
task cryptsetup:build
task e2fsprogs:build
task sgdisk:build
task mkfsvfat:build
task rootfs:build STATEKEY=nodeid
task uki:assemble

export SB_KEY="$HOME/cryptos-sb/sb-2026.key"    # Authenticode + detached sig: the OLD key
export SB_CERT="$HOME/cryptos-sb/sb-2026.crt"
task uki:sign
```

> [!TIP]
> `STATEKEY` here only sets the first-boot default this image would format a
> brand-new node with -- an upgrade reads its mode from the state partition's
> LUKS header and ignores it (see [State-key mode](image-upgrade.md#state-key-mode)).
> It does not need to match the fleet for a rotation build; it would only
> matter if this same image were later used to provision a node from scratch.

Check what came out before shipping it, the same way as [step 5](#5-verify-the-build)
-- but name the certificate explicitly. By the time you get here `$SB_CERT`
is the 2026 certificate, so reusing it in the anchor check would check for
the wrong one:

```bash
sbverify --list build/out/cryptos-amd64.uki   # names the 2026 certificate

grep -q -a -F "$(openssl x509 -in "$HOME/cryptos-sb/sb-2027.crt" -outform DER | base64 -w0)" \
  build/.work/rootfs-amd64/init && echo "anchor stamped (2027)"
```

### 2. Stage and activate the bridge

```sh
cryptosctl --endpoint pki-root.example.org:443 image stage \
  --image build/out/cryptos-amd64.uki
cryptosctl --endpoint pki-root.example.org:443 image activate \
  --confirm "Example Root CA G1"
```

Nothing about `db` changes here. The bridge's Authenticode signature is the
old key, already enrolled everywhere, and its detached signature verifies
against the running node's current (2026) anchor like any ordinary upgrade.
After the reboot, the node's compiled-in anchor is the 2027 certificate: the
next image it will accept has to carry a detached signature from the new key.

Record this image's digest now, before building anything else:

```sh
sha256sum build/out/cryptos-amd64.uki
```

`cryptosctl image status` only ever reports a raw SHA-256, with no label for
which key built it. This is the only record of which digest is the bridge
versus the real image from step 4, once both exist.

> [!CAUTION]
> **On a `STATEKEY=tpm` node, stop here unless a re-provision is acceptable.**
> Steps 1 and 2 are safe: `db` has not changed, and the bridge's Authenticode
> signature is still the key that verified the image before it, so PCR 7 --
> which [holds only "for an image signed with the same Secure Boot
> key"](image-upgrade.md#tpm-backed-nodes) -- does not move. Steps 3, 4 and 5
> below each move it on a `tpm` node, and `image stage`'s reseal has no way
> to follow: it copies the TPM's current PCR values into every sealed copy
> and only overrides PCR 11, so a PCR 7 that will differ at the next boot is
> never accounted for.
>
> - **Step 3** (enrolling the 2027 certificate into `db`) changes what `db`
>   holds, which PCR 7 measures directly.
> - **Step 4** (booting the image whose Authenticode is the 2027 key) moves
>   PCR 7 again, independently of step 3: PCR 7 records which certificate in
>   `db` verified the boot, not just what `db` contains, so switching which
>   key verifies the boot changes it even with both certificates already
>   enrolled.
> - **Step 5** (removing the 2026 certificate, or adding it to `dbx`) changes
>   `db` again, the same way step 3 does.
>
> Any one of those breaks the unseal at the next boot. The one way to rotate
> on a `tpm` node without a re-provision is to keep shipping **split builds
> indefinitely** -- Authenticode always the 2026 key, only the detached
> signature and the anchor moving forward (a bridge of a bridge, and so on).
> That rotates the upgrade anchor and nothing else: `db` and the Authenticode
> key never move, so it does not help if the 2026 key itself was ever
> exposed -- a reinstall is the only fix for that, on a `tpm` node. `nodeid`
> and `kms` nodes do not need this workaround at all: steps 1 through 5 plus
> `dbx` already move the Authenticode key and let the exposed certificate be
> revoked, with no reinstall required.
>
> **What a re-provision costs on a `tpm` node:** it is not a reinstall that
> keeps the CA. The state partition has one keyslot, opened only by the
> TPM-sealed key -- there is no recovery passphrase to fall back to -- and CA
> key export is refused on a `tpm` node by design, because a TPM-sealed key
> is not portable. With no exported copy and no way to reopen the old
> partition, re-provisioning means a **new** CA key and re-issuing everything
> the old one signed, not a reinstall that carries the identity forward.
> `nodeid` and `kms` nodes do not reseal anything and are not affected by any
> of this: only `tpm` mode binds the state key to the booted image.

### 3. Enroll the new certificate

On a `STATEKEY=tpm` node, this is the step the caution above is about --
read it before going further.

Only now does any machine need firmware work: add `sb-2027.der` to `db`,
the same way as [enrolling the first certificate](#3-enroll-the-certificate-secure-boot-on)
(`sbctl enroll-keys --append`, or the firmware / ESXi steps) -- always
appending, never replacing. Leave the 2026 certificate in `db`.

> [!WARNING]
> A node with Secure Boot on refuses to boot any image whose Authenticode
> signature is not in `db`. At every point in this procedure, both ESP slots
> -- active and previous -- have to hold images signed by a key `db` still
> trusts, or an [`image rollback`](#if-it-goes-wrong) onto the previous slot
> can leave the node with nothing bootable. That is why the 2026 certificate
> stays in `db` past this step: the previous slot still holds a
> 2026-Authenticode image (the bridge) until
> one more upgrade lands.

### 4. Build and stage the real image

Build the 2027 image the ordinary way -- Authenticode, detached signature and
anchor all from the same key, no split steps. `PLATFORM` still has to match
the fleet:

```bash
export SB_KEY="$HOME/cryptos-sb/sb-2027.key"
export SB_CERT="$HOME/cryptos-sb/sb-2027.crt"
task image PLATFORM=vmware STATEKEY=nodeid
```

```sh
cryptosctl --endpoint pki-root.example.org:443 image stage \
  --image build/out/cryptos-amd64.uki
cryptosctl --endpoint pki-root.example.org:443 image activate \
  --confirm "Example Root CA G1"
```

Its detached signature verifies against the bridge's anchor (the 2027
certificate), so `image stage` accepts it the same way it would any ordinary
upgrade. Its Authenticode signature needs the 2027 certificate in `db`, which
step 3 already added. After this activation, the previous slot holds the
bridge (2026 Authenticode, 2027 anchor) and the active slot holds this image
(2027 Authenticode, 2027 anchor). Record this image's digest too
(`sha256sum build/out/cryptos-amd64.uki`), so `image status` afterward can
tell it apart from the bridge's.

### 5. Retire the old key

The previous slot still holds the bridge, a 2026-Authenticode image, so
leaving `sb-2026.crt` enrolled in `db` is not a loose end -- it is what keeps
that slot bootable. Removing it is optional, and only safe once **neither**
the active nor the previous digest in `cryptosctl image status` equals the
bridge's sha256sum from step 2. Staging always moves the current active image
into previous before writing the incoming one, so the bridge's digest does
not sit in both slots at once -- after step 4 it is the previous digest; one
more ordinary upgrade moves the step-4 image into previous instead, and only
then has the bridge aged out of the ESP entirely. Once it has, remove
`sb-2026.crt` from `db` on each machine, and add it to `dbx` instead if the
key was ever exposed.

### If it goes wrong

[Rollback](image-upgrade.md#4-if-it-went-badly) works the same as any other
upgrade: `cryptosctl image rollback` followed by `image activate` puts the
retained image back. Rolling back from the real image (step 4) lands on the
bridge, whose anchor is still the 2027 certificate, so staging the real image
again afterward works without rebuilding anything. Rolling back from the
bridge (step 2) lands on the pre-rotation image, whose anchor is the 2026
certificate again -- rotation has to restart from a new bridge. Either way,
per the warning in step 3, do not remove the 2026 certificate from `db` until
you are done rolling back as well as rolling forward.
