# 🚦 Gate 2 — the scheduled rebuild, demonstrated

> **Status: the §9.3 acceptance test passes, on a SIMULATED Debian update.**
> Everything below was executed against the throwaway namespace
> `ghcr.io/laraoci/gate2`, from branch `m5-gate2`, on 2026-08-13. Not one
> command in this document is a claim about what the pipeline would do; each is
> a record of what it did, with the run URL beside it.
>
> **What is simulated, stated once and plainly.** §9.3's acceptance test needs a
> Debian security update published *beneath an unchanged base digest*. On
> 2026-08-13 there was none: the published production image
> `ghcr.io/laraoci/runtime:8.4-trixie-20260812` already carried every available
> fix. The update was therefore induced by pinning the **baseline** build's apt
> index to Debian snapshot `20260803T000000Z` while the **rebuild** used live
> sources. What that means precisely:
>
> - **Simulated:** that a fix became available between the two builds.
> - **Not simulated:** the 49 CVEs, `CVE-2026-64561` among them; that
>   `linux-libc-dev 6.12.100-1` carries them; that `6.12.101-1` fixes them; that
>   the scan gate refused to publish the vulnerable image; that the rebuild
>   produced a different digest from an identical base; and that the only
>   package that moved was the one that was fixed.
>
> The simulation machinery lives on `m5-gate2` and **must never merge** — see
> "Branch hygiene" at the end.

---

## 1. The §9.3 acceptance test

**A rebuild with no upstream digest change still produced a different image,
because Debian had published one.**

| | Baseline | Rebuild |
|---|---|---|
| Run | [31687231176](https://github.com/laraoci/runtime/actions/runs/31687231176) | [31694402513](https://github.com/laraoci/runtime/actions/runs/31694402513) |
| `APT_SNAPSHOT` | `20260803T000000Z` | *(empty — live sources)* |
| `REBUILD_STAMP` | *(empty)* | `20260813` |
| **Base digest** | `sha256:9467f10bf42897dec0abb73ee20c747ebd45463ec9d6fcc4044cb83eba6dade7` | **identical** |
| **Image digest** | `sha256:b6434d0d8dfde4f0d797cfa00957bff609c56cc23c053e9c908197fa2be45801` | `sha256:a72658548029f2164e6f9c14e612b6c834e1bb770e0abe9d8300f3dd3363e6ca` |
| `linux-libc-dev` | 6.12.100-1 | **6.12.101-1** |
| Vulnerability gate | **failed** — 49 fixable HIGH | **passed** — 0 findings |
| Published | nothing | `8.4-trixie-20260813`, rolling tags repointed |

Both figures are the `8.4`/`linux/amd64` leg. The base digest is read from
`BASE_DIGEST=@sha256:…` in each run's own build log, not assumed.

**The difference traces to a package, and to exactly one.** 261 packages
installed on each side; the full sorted `dpkg-query` manifests differ by a
single line:

```diff
--- baseline    ghcr.io/laraoci/gate2/runtime@sha256:b6434d0d…
+++ rebuild     ghcr.io/laraoci/gate2/runtime:8.4-trixie-20260813
@@ -228 +228 @@
-linux-libc-dev 6.12.100-1
+linux-libc-dev 6.12.101-1
```

That is the whole mechanism in one diff: the base did not move, the cache was
invalidated, `apt-get -y upgrade` re-executed, and the one package with a
published fix took it.

### What the baseline's scan failure adds

The baseline was not merely "older". Trivy, gating on **fixable**
CRITICAL/HIGH, found:

```
ghcr.io/laraoci/gate2/runtime@sha256:b6434d0d… (debian 13.6)
Total: 49 (HIGH: 49, CRITICAL: 0)

│    Library     │ Vulnerability  │ Severity │ Status │ Installed │  Fixed     │
│ linux-libc-dev │ CVE-2026-64561 │ HIGH     │ fixed  │ 6.12.100-1│ 6.12.101-1 │
```

All 49 in `linux-libc-dev`, all fixed by `6.12.101-1` — the exact version the
rebuild installed. So §9.3's "the scan then passes on the same packages that
failed last week, or fails identically forever" is not a hypothetical: a
ten-day-old package index is 49 fixable HIGH findings, and the rebuild is what
clears them.

It also demonstrates §9.3's other requirement without any staging: **a scan
failure fails loudly and publishes nothing.** The baseline's six `runtime` legs
failed the gate, `release-required` failed behind them, and no manifest list,
no dated tag and no rolling tag was written.

---

## 2. Two defects this gate caught before the cron went live

### 2.1 The rebuild had never started, and could not have

Run [31689740131](https://github.com/laraoci/runtime/actions/runs/31689740131)
was `rebuild.yml`'s **first ever dispatch**. It ended in `startup_failure`:
zero jobs, zero logs, nothing published.

`release.yml`'s `notes` job requests `contents: write` to create a GitHub
Release. `rebuild.yml`'s calling job granted `contents: read`, on the reasoning
written into the file: `notes` is gated on a tag ref, so a rebuild skips it.
That reasoning is correct about **runtime** and wrong about **startup** —
GitHub validates the permission requirements of every job in a called workflow
*before* it evaluates a single `if:`, so a skipped job's request must still be
granted.

**Why this one matters more than an ordinary bug.** A workflow that fails to
start never runs `report`, and `report` is the entire 🧭 3 mechanism. On the
live Monday cron this would have been a rebuild that failed every week while
the thing built to make failure loud stayed silent — the §9.3 failure mode
exactly, arrived at from a direction §9.3 did not anticipate.

Fixed in `b114252`, with `tests/unit/workflows.bats` pinning the invariant:
every scope any `release.yml` job requests must be granted by `rebuild.yml`'s
caller at a level at least as high.

### 2.2 The regression test for 2.1 was vacuous on its first draft

The first version of that test used jq's `any(...)`, which mikefarah/yq does
not implement. The query errored, the `while read` loop received no input, and
the test **passed with the bug still present**. It was caught only by
re-running it with `contents: read` restored, rather than trusting a green
line.

The committed version refuses to run on an empty read — if the query returns
nothing, that is a broken query, not an absence of things to check — and was
confirmed to fail at `contents: read` and pass at `contents: write`.

Recording it here because a vacuous assertion in the test guarding the
silent-success workflow is the same failure in miniature, and the repository's
answer to it is the same: assert that you measured something, not just that
nothing complained.

---

## 3. 🧭 2 — a scheduled rebuild repoints, carrying no tag

Run [31694402513](https://github.com/laraoci/runtime/actions/runs/31694402513)
ran from a branch ref with no tag anywhere in sight, and:

- minted the dated tag `ghcr.io/laraoci/gate2/runtime:8.4-trixie-20260813`
- repointed the rolling `8.4-trixie` to `sha256:a7265854…`, the same digest
- ran 61 jobs, of which **exactly one was skipped**: `notes`, the tag-gated
  release-notes job

That is `is_rebuild` resolving to the stable channel (D45) without the ref
having anything to say about it.

---

## 4. The GHA layer cache does not restore anything, on any path

This is the finding that most changes how §9.3 should be read, and it was not
anticipated by the plan.

**Measured:** across every leg inspected in runs 31694402513 and 31695922742,
the count of `CACHED` layers is **zero**. RUN 1 re-executed every time — the
build logs show 14 `Get:… deb.debian.org` lines on a run whose `REBUILD_STAMP`
was *unchanged* from the previous run twenty minutes earlier.

It is not eviction. The repository's cache holds 4.65 GiB across 871 entries,
well inside GitHub's 10 GiB budget. It is **scope collision**:

```
$ gh api repos/laraoci/runtime/actions/caches --jq '… | select(.key|startswith("index-buildkit")) | .key | split("#")[0]' | sort -u
index-buildkit-1-0a5bff13
index-buildkit-1-f921bd05
```

Two index names for a thirty-six leg matrix — one per architecture.
`.github/workflows/build.yml` passes `type=gha` with **no `scope=`**, so buildx
uses its default scope for every leg. All eighteen amd64 legs share one cache
index and all eighteen arm64 legs share the other; each leg's export appends a
new version (`…#74`, `#75`, `#76`, … observed seconds apart while six legs ran
in parallel), and each leg's import reads whichever version was written last —
which belongs to a different image, PHP version, or both. A leg therefore
imports an index containing no layer of its own lineage, and matches nothing.

### What this means for §9.3, stated carefully

- **The release path's cache behaviour is "unchanged" in the most literal
  sense: it restored nothing before this milestone and restores nothing now.**
  Gate 2 asked for a release-path build "still restoring from `type=gha` on a
  layer the scheduled path busts". That demonstration is **not possible**,
  because no such restore exists to show. Recording the absence rather than
  staging something that would look like the requested evidence.
- **D41's premise is currently inoperative.** The trap §9.3 is written
  against — the cache restoring the apt layer, `apt-get -y upgrade` never
  running, a byte-identical image reported as this week's security rebuild —
  cannot occur today, because the layer is never restored.
- **That is an accident, not a safeguard, and it argues for `REBUILD_STAMP`
  rather than against it.** The cache is misconfigured in a way that happens to
  disable the trap. The moment anyone adds `scope=` — which is the obvious fix
  for a release path paying export costs for zero benefit — the cache starts
  working, and the trap becomes live on the same day. `REBUILD_STAMP` is what
  makes that change safe to make.
- **Consequently this gate demonstrates the OUTCOME of §9.3, not its
  MECHANISM.** Section 1 proves that an unchanged base produced a different
  image carrying the fixed package. It does *not* prove that `REBUILD_STAMP`
  was what caused the apt layer to re-execute, for two independent reasons:
  `APT_SNAPSHOT` also changed between the two builds (§1's stated confound),
  and nothing would have been restored from cache in any case. The mechanism is
  proven at unit scale in `tests/unit/rebuild-cache.bats`, against a
  `type=local` cache that does restore, where a changed stamp re-executes the
  layer and an unchanged one does not.

### The separate defect this exposes

The release path exports layer cache on all 36 legs, every release, and reads
back nothing. That is pure cost. The fix is a per-leg scope, roughly
`type=gha,scope=${{ inputs.image }}-${{ inputs.php }}-${{ inputs.platform }}`.

It is deliberately **not** made here: it is a change to the release path's
build performance, it belongs to `build.yml` rather than to the rebuild, and
D41 already ruled that the cost side of the cache question sits outside the
rebuild's remit. It should be filed as its own issue. **Whoever takes it must
know that fixing the scope arms the §9.3 trap**, and that `REBUILD_STAMP` and
the acceptance test in this document are what stand between that fix and a
silently useless weekly rebuild.

---

## 5. D36 — a same-day rebuild appends a counter, it never overwrites

Run [31695922742](https://github.com/laraoci/runtime/actions/runs/31695922742),
dispatched the same UTC day as 31694402513:

| Tag | Digest | |
|---|---|---|
| `8.4-trixie-20260813` | `sha256:a7265854…` | **unchanged** — the dated tag from the earlier run |
| `8.4-trixie-20260813-2` | `sha256:afbc58fc…` | newly minted |
| `8.4-trixie` (rolling) | `sha256:afbc58fc…` | repointed to the newer |

So a dated tag that a consumer has pinned did not move underneath them, and the
rebuild is visible as a new reference — §8's guarantee, observed.

### A caveat that matters more than the counter

The `-2` image has a **different digest** from the `-1` image but an
**identical package set** — both 261 packages, `diff` clean. The digest moves
on every build regardless of content, because the image config carries build
metadata and the provenance attestation references the run.

**Therefore "the rebuild produced a different digest" is not, by itself,
evidence that the rebuild did anything.** A rebuild that restored every layer
from cache and re-executed nothing would *still* publish a new digest. §9.3's
acceptance test as worded — "must still produce a different image" — is
satisfied by a no-op rebuild, and any check written against digest inequality
alone would pass forever while the rebuild silently did nothing.

The load-bearing assertion is the one in §1: the **package manifest** moved,
and moved on exactly the package with a published fix. That is why this
document diffs `dpkg-query` output rather than comparing digests, and it is
worth correcting the spec's wording on.

---

## 6. What this gate did NOT demonstrate

🚦 Gate 2 asks for six things. Three are demonstrated above, one is
demonstrated in a weaker form than requested, and **two were not run**. Listing
them rather than letting the reader infer coverage from what happens to be
present.

| Gate 2 bullet | State |
|---|---|
| §9.3 acceptance test, demonstrated | **done** (§1), on a simulated update, outcome not mechanism (§4) |
| Release path's cache unchanged | **not demonstrable** — nothing restores on any path (§4) |
| Channel resolution repoints a `schedule` run; dated suffix correct | **done** (§3, §5) |
| Contract untouched | **done** (§6, below) |
| `deprecated` version neither rebuilt nor repointed, deliberate release still publishes | **NOT RUN** |
| Forced scan failure opens exactly one issue; re-run opens no second | **NOT RUN** |

The last two require a further deprecation cycle and a forced-failure cycle
against the throwaway namespace. They were stopped deliberately, to review the
findings in §4 and §5 before spending more CI, not because anything blocked
them.

**The scan-failure path is partially evidenced anyway, from §1:** the
snapshot-pinned baseline failed the vulnerability gate on all six `runtime`
legs and published nothing — no manifest list, no dated tag, no rolling tag. So
"a scan failure fails loudly rather than publishing" is observed. What is *not*
observed is the issue-filing half of 🧭 3: whether exactly one label-keyed issue
is opened, reused on a second failure, and closed on the next pass.

**And 🧭 3 has one confirmed hole already**, from §2.1: a `startup_failure`
files no issue at all, because `report` cannot run in a workflow that never
started. That class of failure is invisible to the mechanism designed to make
failure loud. Worth deciding whether anything should watch for it — a missing
weekly run is not something the repository can currently notice.

---

## 7. Branch hygiene

`m5-gate2` carries two kinds of commit and they must be separated on the way
out:

| Commit | Contents | Destination |
|---|---|---|
| `dce42a2` | `APT_SNAPSHOT` in `build.yml`, `release.yml`, `images/runtime/Dockerfile` | **never merges** — delete with the branch |
| `b114252` | `contents: write` fix + its regression test | **cherry-pick to `main`** as a LOCI-049 fix |

`b114252` touches only `.github/workflows/rebuild.yml` and
`tests/unit/workflows.bats`, and contains no simulation code, so it
cherry-picks cleanly.

**The runtime contract was not touched.** `git diff main...m5-gate2 --
tests/structure/` is empty; the only `images/` change is the simulation `ARG`,
which leaves with the branch.
