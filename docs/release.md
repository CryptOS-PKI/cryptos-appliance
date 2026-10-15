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
- **Order:** `cryptos-node`, `cryptos-manager`, `cryptos-web` and `website` first, at the commits
  `release/pins.yaml` names; `cryptos-appliance` last. Publishing the appliance's draft is what
  starts this workflow, and its `guard` job checks the other tags already sit at their pins.
- **A merge freeze** runs from the moment the pins are set until the appliance is published:
  Release Drafter's draft targets `main`, so a later merge would move the draft and the published
  tag would land on the wrong commit.
- **Tags are immutable** once pushed (a repository ruleset on `refs/tags/v*`), except that this
  workflow's `notes` job edits the release body after publish to add how it was tested.

## The workflow (`.github/workflows/release.yml`)

Two ways in, one pipeline:

- **Rehearsal** — `workflow_dispatch` on `main`, by me only (`guard` refuses a dispatch against any
  other ref, so `assets` can never run off a manual dispatch). Runs everything except `notes` (there
  is no tagged release yet to add a tested section to). This is the pre-publish proof: I only
  publish a draft after a green rehearsal against that draft's pins.
- **Release** — a `v*` tag push. The authoritative run, on the exact tag.

```text
guard -> services -> reproducibility -> probe -> gate -> assets -> notes
```

| Job | Runs on | Does |
|---|---|---|
| `guard` | hosted | `task release:guard`: `release/pins.yaml` is well-formed, every pin is a full commit SHA, every pin is reachable, and the `cryptos-node` pin matches `go.mod` |
| `services` | hosted | builds the FleetOS Manager image from the pinned `cryptos-manager` and `cryptos-web` commits and runs it read-only with its health check, builds the web console and runs its release-bundle check, and lints `chart/fleet-manager`; pushes nothing |
| `reproducibility` | hosted | `task release:reproducible`: builds the unsigned image twice from the same commit in separate workspaces and compares every output byte for byte |
| `probe` | the lab ESXi runner | a tiny, 5-minute check that a lab runner accepts this ref at all, before the 240-minute `gate` job does; see "The runner group" below |
| `gate` | the lab ESXi runner | `task gate:esxi`: builds the baseline and the candidate with a throwaway key and proves on real hardware that the candidate installs, boots, upgrades in place with state kept (including power cuts mid-upgrade) and rolls back; see [the release gate](release-gate.md) |
| `assets` | hosted, tag only | builds the unsigned ISOs and UKIs (`tpm` and `nodeid`) and `cryptosctl`, checks nothing is signed, and attaches them with `SHA256SUMS` and `build-manifest.json` to the tag's release |
| `notes` | hosted, tag only | adds "How this release was tested" to the release body: the commit set, the gate's step table and a link to the run |

`guard` runs on both entry points. On a rehearsal dispatch it only proves the pins are internally
consistent, since the other repos' tags do not exist yet to check against.

The `gate` job runs on the self-hosted ESXi runner through the `lab-esxi` environment, which holds
no secrets: it only gates on a required reviewer. The runner fetches the gate's ESXi account from
Sneakers at run time and exports it into the job; nothing about the lab (its address, datastore,
network or account) is a GitHub secret, variable or literal in this repository. A `concurrency`
group shared by the rehearsal and the release makes sure only one gate runs at a time. The gate's
VMs take a normal DHCP address on the lab LAN; there is no reserved pool to maintain (see
[the release gate](release-gate.md)).

### The runner group

`probe` and `gate` run on the self-hosted `lab-esxi` runner group. GitHub's org runner-group
"selected workflows" access list refuses a wildcard ref, so by default it only allows
`release.yml@refs/heads/main` (the rehearsal). **Before publishing a release draft, I add the exact
tag to that list** (`release.yml@refs/tags/<tag>`, e.g. `refs/tags/v0.1.0-rc.1`), through the
org's runner-group settings. A `GITHUB_TOKEN` cannot read or change org runner-group settings (it
needs an org-admin token), so this cannot be checked or done from the workflow itself: if I forget,
`probe` never starts, rather than the expensive `gate` job hanging for no runner. If that happens,
I add the entry and re-run the workflow on the same tag.

## Checking what you build

- The release notes list every repo's tag and commit SHA; `git rev-parse v0.1.0-rc.1^{commit}` in a
  fresh clone of each repo has to print the listed SHA.
- The Go modules (`cryptos-node`, `cryptos-manager`, `cryptos-appliance`) are recorded in the
  public Go checksum database, so `go mod download` refuses altered source.
- The image you build carries `build-manifest.json` and stamped build info naming the
  `cryptos-node` module version, so `cryptosctl version` and `image status` on a running node name
  the source it was built from.
- There is nothing else to check: no project checksum, signature, attestation or SBOM exists for
  any release file, because the project signs nothing (see
  [Secure Boot](secure-boot.md#unsigned-builds-and-the-release-assets)).

## If the gate fails after I publish

The candidate failed, and the tag is already live.

1. I save each of the six repos' release notes (`gh release view --json body`) for the record,
   with the run link.
2. I set the `v*` tag ruleset to disabled in each repo.
3. I delete each release and its tag (`gh release delete <tag> --cleanup-tag`).
4. I set each ruleset back to active.
5. Once the cause is fixed, the next candidate gets the next rc number — never the same tag name.

A runner reset or a lab outage mid-run is an environment failure, not a code failure: I re-run the
same workflow run on the same tag instead of cutting a new one.
