# The ESXi release gate

A CryptOS release is tested source. The gate is the test: it builds the images from exactly the
tagged source with throwaway keys made for the run, proves on a lab VMware ESXi host that they
install, boot, upgrade in place from an older build with their state kept (including power cuts
mid-upgrade), roll back and re-key, and then throws everything away. Nothing the gate builds is
published, cached or uploaded.

The driver is `test/gate/run.sh` (`task gate:esxi`), with its helpers in `test/gate/lib.sh` and one
file per step in `test/gate/steps/`. The release workflow runs it on a self-hosted runner next to
the lab host; it can also be run by hand from a Linux machine that reaches the lab.

## What it checks

| # | Step | Proves |
|---|---|---|
| B | Build the upgrade baseline (`release/pins.yaml` `upgrade_from`, with that commit's own build recipe) and the candidate (this checkout, `nodeid` and `tpm`), both signed and anchored with the run's key K, and a negative image signed with a second key W. Check both with `sbverify --cert K` and the `.sig`, refuse W, find K exactly once in each `/init`, and check three candidate UKIs fit the 512 MiB ESP | the images are what the steps think they are |
| 1 | Install a Root and an Intermediate from the baseline ISO through maintenance `config apply`; Root ceremony; the Root signs the Intermediate; the Intermediate issues two leaves and revokes one | the baseline comes up as in the field |
| 2 | The candidate `cryptosctl` runs `status` and `image status` against both baseline nodes | the new CLI talks to the old node |
| 3 | Stage the W-signed image and an unsigned image on the Intermediate | both refused, nothing written |
| 4 | Stage the candidate and cut the power during the ESP write | boots the baseline, state intact |
| 5 | Stage completes, cut the power before `activate` | boots the candidate (stage already put it on the boot path), state intact; then rolls back for step 6 |
| 6 | Stage and `activate`, cut the power during the candidate's first boot | comes up on the candidate, state intact |
| 7 | Same CA serial and key, the old leaf in the inventory, the revoked serial on the CRL, OCSP good and revoked, `audit verify` intact, a new leaf issues | an upgrade is not a re-key |
| 8 | `image rollback` and `activate`, issue a leaf, then upgrade again | rollback keeps the state and the CA still signs |
| 9 | The Root: stage, activate, same serial and key, audit chain intact, signs the Intermediate's renewal CSR | the Root's upgrade path |
| 10 | The Intermediate re-keys (`ca rotate-key`, the Root's `ca sign-subordinate`, `ca submit-rotation`): the new certificate chains to the Root under a new key, a leaf issues under it, the revocation made before the re-key is still on the CRL and over OCSP, and the audit chain verifies | the subordinate re-key path, on every release |
| 11 | Fresh install of the candidate (`nodeid`) as a Root, with its ceremony | a new install works |
| 12 | Secure Boot on with K enrolled in `db` | manual for now: enrolling a VM's `db` is not automated, so step B's `sbverify --cert K` covers the signature |
| 14 | `task e2e:esxi` (cryptos-manager) against the live Root and Intermediate, with step B's candidate served as the image under test | the manager's own write paths work against a real node, on every release |
| 13 | Destroy the VMs, remove the run's datastore folder; the keys are shredded when the gate exits | nothing outlives the run |

Every step after B runs only when the steps it needs passed; the rest are reported as skipped. The
gate prints this table at the end (and adds it to the job summary in Actions); the release notes'
"How this release was tested" section is rendered from it.

TPM mode (install, reseal on upgrade, rollback) is not on this host: a standalone ESXi host has no
vTPM. The QEMU + swtpm suite (`task e2e:image`, `ci-e2e-image.yml`) proves it on the same commit.

### Serving the candidate for step 14

Once step B builds `candidate.uki`, `gate_serve_start` (`test/gate/run.sh`) serves it over plain
HTTP from the runner's own address on the lab network (`gate_lab_addr`, never loopback, since the
gate's VMs have to fetch it themselves), for the rest of the run; `gate_serve_stop` ends it from
`gate_cleanup`, win or lose. Step 14 points cryptos-manager's `task e2e:esxi` at that URL through
`E2E_IMAGE_URL`, at `candidate.uki.sig` through `E2E_IMAGE_SIGNATURE_PATH`, and at the candidate's
already-recorded `candidate-sha` state through `E2E_IMAGE_SHA256`, so its image stage/activate/
rollback write paths run on every routine gate pass instead of only when someone supplies an image
by hand (cryptos-manager's `docs/e2e-esxi.md` keeps that by-hand path as the fallback). A run
without a built candidate, or whose lab address can't be found, serves nothing and step 14 reports
skip rather than failing the gate.

Step 14 also needs a pinned `cryptos-manager` checkout (`GATE_MANAGER_DIR`, which the release
workflow checks out from `release/pins.yaml` alongside the appliance itself) and `docker`, for
`task e2e:esxi`'s own throwaway Postgres; either missing is also a skip, named. It targets the
gate's live Root and Intermediate (the Intermediate first, since it is the one `test/e2e/esxi`
drives issuance and SCEP against), with neither marked spare, so the manager's own rekey, escrow,
enrolment and decommission steps report their own skip on a routine gate run.

## Keys

- K (the run's Secure Boot key), W (the negative key), the bootstrap admin identity and every leaf
  key are made in a `mktemp -d /dev/shm/...` directory, on tmpfs, and shredded when the gate exits,
  whatever happened before.
- Nothing that holds a key or carries K as its anchor (the baseline and candidate images, `init`,
  the rootfs) is cached or uploaded. The candidate is built in a throwaway clone that is removed
  at exit. Only the kernel and the static tools, which carry no key material, are cached, keyed by
  a hash of their pins and build scripts (`GATE_TOOLS_CACHE`, default `.cache/gate/tools`).

## Settings

The gate reads its lab settings from a file on the runner, `/etc/cryptos-gate/lab-esxi.env`
(`GATE_ENV_FILE` overrides the path). GitHub holds none of them: no URL, address, datastore,
network name or credential.

| Setting | What it is |
|---|---|
| `GATE_ESXI_URL` | the ESXi host's SDK URL |
| `GATE_ESXI_THUMBPRINT` | the host certificate thumbprint, in the form govc's known-hosts file takes; govc checks it (never `-k`) |
| `GATE_ESXI_DATASTORE` | the only datastore the gate writes to (ISOs, serial logs, VM disks) |
| `GATE_ESXI_POOL` | the only resource pool the gate creates VMs in |
| `GATE_ESXI_NETWORK` | the port group the gate VMs attach to |
| `GATE_NTP` | the NTP server the nodes sync against |
| `GATE_SNEAKERS_SECRET` | the name of the vault secret that holds the ESXi account |

The ESXi account (a lab-only local account whose role covers the gate's pool and datastore
folder) is read at run time from the Sneakers vault with the runner's scoped, read-only token. The
runner wrapper fetches the secret `GATE_SNEAKERS_SECRET` names (fields `username` and `password`)
and exports them as `GATE_ESXI_USERNAME` and `GATE_ESXI_PASSWORD`; `gate_fetch_account` in
`test/gate/lib.sh` is the one place the gate reads them, and govc gets them through its
environment for each call, never on a command line.

Where the gate writes:

- every file under `cryptos-gate-<run id>/` on `GATE_ESXI_DATASTORE`;
- every VM named `cryptos-gate-<run id>-<role>` in `GATE_ESXI_POOL`, with a fixed MAC from
  VMware's manual range derived from the run id;
- teardown names only those VMs and that folder.

One gate runs at a time; the release workflow's concurrency group enforces it.

### Finding a node's address

There is no reserved address pool: a gate VM takes a normal DHCP address on the lab LAN, both
during maintenance and, since it keeps whatever address it is first handed, once it is installed.
The appliance's image carries no VMware Tools guest agent to self-report that address the plain
way, so `gate_discover_addr` (`test/gate/lib.sh`) reads it from the ESX host's own ARP/DHCP
snooping instead (`govc vm.ip -esxcli`, which needs the host's `/Net/GuestIPHack` setting enabled),
confirmed once its HTTPS listener answers. The node's `MachineConfig` gets the real prefix and
gateway for that address, read from the runner's own routing table (`gate_network_for`,
`test/gate/lib.sh`): the runner sits on the same lab network as the gate VMs, so the connected
route that covers the VM's address gives the prefix, and the default route on that same interface
gives the gateway. A VM whose address isn't on a network the runner is directly connected to, or
whose network has no default route, fails the step, naming the VM, never an address.

## Lab values stay out of the logs

The repository and its Actions logs are public. The gate sends its own stdout and stderr through a
redaction filter (`gate_redact`) before anything is printed: the value of every setting above, the
account, the host name inside the URL, and any IPv4 address, including a node's DHCP address (as
`[ipv4]`), are replaced at the source. The step table it writes is filtered the same way. In
Actions the values are also registered with `::add-mask::`; an address discovered mid-run is
registered the moment it is learned (`gate_mask_now`), since by then the redaction filter is
already running and would otherwise mask its own placeholder instead of the value. The gate
uploads nothing: no artifacts, serial logs or govc output.

## Running it by hand

From a Linux machine with `govc`, `go`, `task`, the image toolchain (see `build/README.md`) and a
route to the lab network:

```bash
set -a; source ./my-lab-gate.env; set +a   # the settings above plus GATE_ESXI_USERNAME/PASSWORD
task gate:esxi
```

| Variable | Use |
|---|---|
| `GATE_ONLY=B,11,13` | run only these steps (the rest report skipped) |
| `GATE_SUMMARY_OUT=<file>` | also write the step table there |
| `GATE_BASELINE_COMMIT=<sha>` | override the baseline from `release/pins.yaml` |
| `GATE_BUILD_TPM=0` | skip the `tpm` candidate build |
| `GATE_CUT_AFTER=<s>` | seconds into the stage before step 4's power cut (default 3); step 4 fails and says so when the stage finished first |
| `GATE_FIRSTBOOT_CUT_AFTER=<s>` | seconds into the candidate's first boot before step 6's cut (default 3) |
| `GATE_BOOT_TIMEOUT`, `GATE_DISCOVER_TIMEOUT` | seconds to wait for a node (900) and for a maintenance address (600) |
| `GATE_DISK_GB` | the gate VMs' disk size (16) |
| `GATE_MANAGER_DIR=<path>` | a cryptos-manager checkout, pinned to `release/pins.yaml`'s `cryptos-manager` commit, for step 14's `task e2e:esxi`; without it step 14 reports skip |
| `GATE_SERVE_PORT`, `GATE_E2E_PG_PORT` | the candidate image server's port (8099) and step 14's throwaway Postgres port (15432) |

Exit status: 0 when every step passed or was skipped, 1 when a step failed, 2 when a setting, the
account or a tool is missing.

The driver's own tests run offline, with a stand-in `govc` and `cryptosctl`
(`test/gate/run_test.sh`, `test/gate/redact_test.sh`, both in `task build:test`).
