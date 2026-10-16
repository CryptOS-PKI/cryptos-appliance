# The release process

A CryptOS release is tested source: the matching tags in the project's repos, the release notes,
the source archives GitHub generates for each tag, and unsigned images built from that exact
source (see [Secure Boot](secure-boot.md#unsigned-builds-and-the-release-assets)). I build and sign
nothing myself; the FleetOS Manager image and its Helm chart are the one exception, published by
cryptos-manager's own workflow on the same tag (see its docs for that).

Prereleases are rc only (`v0.1.0-rc.1`, then `rc.2` if a candidate fails), and the first stable
release is `v0.1.0`. A tag name is never reused: a failed candidate is followed by the next rc
number.

## The tag model

- **Publishing the release-drafter draft is the tag.** Release Drafter keeps one draft per repo on
  every push to `main`. I publish each draft as a prerelease; publishing creates the tag at the
  draft's target commit. Nothing tags by hand and no workflow creates a tag.
- **Order:** `cryptos-node`, `cryptos-web`, `cryptos-manager` and `docs` first, at the commits
  `release/pins.yaml` names; `cryptos-appliance` last. Publishing the appliance's draft is what
  starts this workflow, and its `guard` job checks the other tags already sit at their pins.
- **cryptos-web before cryptos-manager, same version:** the two are versioned in lockstep. The
  manager's release image embeds the web console from `cryptos-web`'s tag of the same name and
  fails when that release isn't published yet. Each repo's Release Drafter resolves its next
  version from its own labels, so I check both drafts carry the same version before publishing
  either; if they differ, I dispatch the lower one's Release Drafter workflow with a `version`
  input to match.
- **A merge freeze** runs from the moment the pins are set until the appliance is published:
  Release Drafter's draft targets `main`, so a later merge would move the draft and the published
  tag would land on the wrong commit.
- **Tags are immutable** once pushed (a repository ruleset on `refs/tags/v*`). The release notes
  are Release Drafter's notes as published; no workflow edits them.

## The workflow (`.github/workflows/release.yml`)

Two ways in, one pipeline:

- **Rehearsal** — `workflow_dispatch` on `main`, by me only (`guard` refuses a dispatch against any
  other ref, so `assets` can never run off a manual dispatch). Runs everything except `assets` (there
  is no tagged release yet to attach them to). This is the pre-publish proof: I only
  publish a draft after a green rehearsal against that draft's pins.
- **Release** — a `v*` tag push. The authoritative run, on the exact tag.

```text
guard -> services -> reproducibility -> e2e -> assets
```

| Job | Runs on | Does |
|---|---|---|
| `guard` | hosted | `task release:guard`: `release/pins.yaml` is well-formed, every pin is a full commit SHA, every pin is reachable, and the `cryptos-node` pin matches `go.mod` |
| `services` | hosted | builds the FleetOS Manager image from the pinned `cryptos-manager` and `cryptos-web` commits and runs it read-only with its health check, builds the web console and runs its release-bundle check, and lints `chart/fleet-manager`; pushes nothing |
| `reproducibility` | hosted | `task release:reproducible`: builds the unsigned image twice from the same commit in separate workspaces and compares every output byte for byte |
| `e2e` | hosted | calls `ci-e2e-image.yml`, the QEMU full-image suite, on this commit: boots the real image (OVMF, with a software TPM) as a Root and an Intermediate and drives every step over the mTLS API, and in its bridge job upgrades a node on the bridge build (a77ae5b) to this commit; the run's job summary shows both step tables |
| `assets` | hosted, tag only | refuses to run if the suite skipped, then builds the unsigned ISOs and UKIs (`tpm` and `nodeid`) and `cryptosctl`, checks nothing is signed, and attaches them with `SHA256SUMS` and `build-manifest.json` to the tag's release |

`guard` runs on both entry points. On a rehearsal dispatch it only proves the pins are internally
consistent, since the other repos' tags do not exist yet to check against. It also prints each
repo's release-drafter draft next to its pin and fails on a wrong tag, target or prerelease flag.
The workflow token can't list another repo's drafts, so a draft it can't see is a warning, and I
check those drafts by hand before publishing.

Every job runs on GitHub-hosted runners: there is no self-hosted runner, lab host or credential
in the release path. The QEMU suite is the only proof that the image boots and works. It covers
the ceremony, subordinate signing, issuance, revocation and OCSP, ACME, EST, the RFC 3161 TSA,
re-certify, escrow and restore, image upgrade in place on a software-key node and on a TPM node,
and the console reset. Its bridge job proves the upgrade my production nodes will take: it builds
the bridge build (cryptos-node a77ae5b, from that commit's own recipe) and the candidate, both
signed and anchored with one throwaway key made for the run, boots the bridge as a nodeid Root with
Secure Boot off, runs the ceremony, issues two leaves and revokes one, then stages the candidate
with the bridge-era `cryptosctl` and activates it. The candidate has to answer on
`cryptos.node.v1` with the same CA serial and key, list both leaves, show the revocation on the CRL
and over OCSP, keep the config, pass `audit verify` and issue a new leaf. It then rolls back to the
bridge, which has to answer again, and upgrades a second time. The same job proves the sign-time
anchor: it builds the candidate unsigned with no anchor, signs it with `cryptosctl image sign` and a
second throwaway key, checks it with `sbverify --cert`, boots it, refuses an image signed by the
other key, and stages, activates and boots a second image signed the same way. Nothing in a release is run on
VMware or other hardware: power cuts mid-upgrade and the FleetOS Manager's end-to-end run against
live nodes are not proven per release.

## Checking what you build

- `release/pins.yaml` at the appliance's tag lists every repo's commit SHA; `git rev-parse
  v0.1.0-rc.1^{commit}` in a fresh clone of each repo has to print the pinned SHA.
- The Go modules (`cryptos-node`, `cryptos-manager`, `cryptos-appliance`) are recorded in the
  public Go checksum database, so `go mod download` refuses altered source.
- The image you build carries `build-manifest.json` and stamped build info naming the
  `cryptos-node` module version, so `cryptosctl version` and `image status` on a running node name
  the source it was built from.
- There is nothing else to check: no project checksum, signature, attestation or SBOM exists for
  any release file, because the project signs nothing (see
  [Secure Boot](secure-boot.md#unsigned-builds-and-the-release-assets)).

## If the release run fails after I publish

The candidate failed, and the tag is already live.

1. I save each of the six repos' release notes (`gh release view --json body`) for the record,
   with the run link.
2. I set the `v*` tag ruleset to disabled in each repo.
3. I delete each release and its tag (`gh release delete <tag> --cleanup-tag`).
4. I set each ruleset back to active.
5. Once the cause is fixed, the next candidate gets the next rc number — never the same tag name.

A hosted-runner hiccup mid-run (a timeout, a download that failed) is an environment failure, not
a code failure: I re-run the same workflow run on the same tag instead of cutting a new one.
