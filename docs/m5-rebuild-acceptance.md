# 🚦 Gate 2 — the scheduled rebuild, demonstrated

> **Status: all six Gate 2 bullets exercised. The §9.3 acceptance test passes, on a SIMULATED Debian update.**
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

## 6. §13 — the deprecation triple, with a control

`8.3` was marked `deprecated` on the scratch branch via
`make deprecate PHP=8.3 ON=2026-08-13`, which set `status` and `deprecated_on`
together and preserved every comment in `config/images.yml` (its own census
check). The matrix dropped from 36 legs to 24.

| Effect (§13) | Evidence |
|---|---|
| **Not rebuilt** by the schedule | [31716942050](https://github.com/laraoci/runtime/actions/runs/31716942050) — 24 legs, **zero** jobs mentioning 8.3 |
| **Rolling tag frozen** | `8.3-trixie` still `sha256:b54644d1…` after the rebuild — unmoved |
| *control:* a supported version still moves | `8.4-trixie` → `sha256:16543a08…` in the same run |
| **Dated tags kept forever** | `8.3-trixie-20260813` and `-2` still resolve; no `-3` was ever minted for 8.3 |
| **Deliberate release still publishes** | [31718533341](https://github.com/laraoci/runtime/actions/runs/31718533341), `workflow_dispatch` with `include_deprecated=true`, published `8.3-trixie-20260813-4` |
| …and still does not repoint | `repoint: skipped` in that run |

The control row is the point: "the tag did not move" is only evidence if
something else's tag *did* move in the same run.

### The freeze is structural, not filtered

Tracing every path by which a deprecated version could reach the repoint job:

| Path | `include_deprecated` | `is_stable_release` | Outcome |
|---|---|---|---|
| Tag push | `false` — not an input on `push:` | `true` | 8.3 never built |
| Dispatch + `include_deprecated=true` | `true` | **`false`** — branch ref | 8.3 built, **repoint skipped entirely** |
| Scheduled rebuild | `false` — never passed (rebuild.yml) | `true` | 8.3 never built |

The only path that builds a deprecated version is the one path where the
repoint does not run, and every path where the repoint runs is one that cannot
build it. Trap 2's half-deprecation would require breaking two independent
mechanisms at once.

**A correction to the plan's wording.** 🚦 Gate 2 asked to show "a deliberate
**tagged** release of that same version still would [publish]". That is not
achievable and never was: a tag push carries no `include_deprecated` input, so
a tag can never publish a deprecated version. The deliberate release is
specifically a `workflow_dispatch`, which is what §13 says. Demonstrated in
that form.

### The deprecation tooling's own tests break when a deprecation happens

Deprecating 8.3 on this branch turned **three unit tests red**, and none of
them is a regression — each assumes 8.3 is `supported`, by reading the **live**
`config/images.yml`:

| Test | Why it fails |
|---|---|
| `build-chain: a child is built with PARENT_REF pointing at its parent` | hardcodes `--php 8.3`; `build-chain.sh` now refuses it — *"error: '8.3' is not a supported PHP version … supported: 8.4 8.5"* |
| `deprecate: marks the version and records the freeze date (§13)` | `setup()` does `cp config/images.yml "$TMP/images.yml"`, then expects to deprecate 8.3 — but it is already deprecated, so `deprecate.sh` correctly no-ops and the date stays `2026-08-13`, not the expected `2026-11-30` |
| `deprecate: is idempotent` | same cause |

Confirmed as config-state coupling rather than breakage: running the same
`build-chain.sh` command against `origin/main`'s config emits
`PARENT_REF=ghcr.io/laraoci/runtime:8.3-trixie` exactly as the test expects.

**This will happen on `main` the day 8.3 is genuinely deprecated** — that is,
the first time the LOCI-050 tooling is used for its actual purpose, the suite
that tests it goes red. `tests/fixtures/deprecated.yml` already exists and is
the right input for both files; copying the live config into a fixture couples
the tests to a value the tooling is designed to change.

Not fixed here — it is outside 🚦 Gate 2 and this branch does not merge — but
it should be fixed before any real deprecation.

---

## 7. 🧭 3 — one reusable issue, commented then closed

Starting state: **no issue carried the `scheduled-rebuild` label**, which is
what makes "exactly one" mean anything afterwards.

The failure was forced by removing `--ignore-unfixed` from the vulnerability
gate — chosen over widening the severity because an *unfixable* CVE is the
precise scenario 🧭 3 names, and verified locally (168 findings, exit 1)
before pushing, so no CI run was spent discovering whether it would fail.

| Run | Result | Label state after |
|---|---|---|
| [31719715866](https://github.com/laraoci/runtime/actions/runs/31719715866) | failure | **#68 opened**, 0 comments |
| [31720467009](https://github.com/laraoci/runtime/actions/runs/31720467009) | failure | **#68 still the only issue**, +1 comment |
| [31721047200](https://github.com/laraoci/runtime/actions/runs/31721047200) | success | **#68 CLOSED** — *"Rebuild passed on … Closing."* |

The issue body classified the failure correctly as **`vulnerability scan`**
rather than "build", named all four failing `runtime` legs with their step, and
stated that nothing was published and no rolling tag moved. Four legs, not six,
because 8.3 was deprecated by then — the two mechanisms composed correctly
without being designed together.

The `report` job's own conclusion is `failure` on the failing runs. That is
correct: §9.3 requires the run to fail *as well as* file, so it files and then
exits 1.

---

## 8. Three robustness gaps in the reporting path

None of these blocked the gate. All three matter for a job that runs
unattended, and all three were observed rather than reasoned about.

1. **A `startup_failure` files nothing.** §2.1's failure produced no issue,
   because `report` cannot run in a workflow that never started. The repository
   currently cannot notice a weekly rebuild that stopped happening.
2. **`cosign sign` has no retry.** Run 31718533341 lost one leg to
   `Post "https://fulcio.sigstore.dev/api/v2/signingCert": read: connection
   reset by peer` — a transient Sigstore network failure. On a Monday cron that
   is a red rebuild and a filed issue for a reason unrelated to security.
   Triage is possible (the issue names the signing step), but the rebuild will
   periodically cry wolf.
3. **"Exactly one issue" is an assumption, not an invariant.** The lookup is
   `gh issue list --label scheduled-rebuild --state open --limit 1` and takes
   `.[0]`. If a second labelled issue ever existed — filed by hand, or the
   label applied to something else — the workflow would comment on whichever
   GitHub returned first and ignore the other indefinitely.

---

## 9. What this gate did NOT demonstrate

All six 🚦 Gate 2 bullets are now exercised. One cannot be satisfied as
written, and one is satisfied in a weaker form than the wording implies.
Stating both rather than letting coverage be inferred.

| Gate 2 bullet | State |
|---|---|
| §9.3 acceptance test, demonstrated | **done** (§1) — on a *simulated* update, and proving the **outcome, not the mechanism** (§4) |
| Release path's cache unchanged | **not demonstrable** — nothing restores on any path (§4) |
| Channel resolution repoints a `schedule` run; dated suffix correct | **done** (§3, §5) |
| `deprecated` neither rebuilt nor repointed; deliberate release still publishes | **done** (§6), with a control |
| Forced scan failure opens exactly one issue; re-run opens no second | **done** (§7), plus the close-on-pass half |
| Contract untouched | **done** (§10) |

The two qualifications, restated so they are not lost in a table:

- **"The release path still restores from `type=gha`" cannot be shown**,
  because no restore exists anywhere (§4). Recorded as an absence rather than
  staged into something resembling the requested evidence.
- **§1 proves that an unchanged base produced a different image with the fixed
  package. It does not prove `REBUILD_STAMP` caused it** — `APT_SNAPSHOT` also
  changed, and nothing would have restored from cache regardless. The mechanism
  is proven only at unit scale, in `tests/unit/rebuild-cache.bats`.

**What remains genuinely untested at full scale** is therefore the single
claim the milestone rests on: that `REBUILD_STAMP` defeats a cache which would
otherwise hide a Debian update. It cannot be tested until the cache actually
restores something — which is issue #67. Whoever fixes the cache scope is also
the person who can finally test this, and §9.3's corrected acceptance test is
how they should.

---

## 10. Branch hygiene

`m5-gate2` carries two kinds of commit and they must be separated on the way
out:

| Commit | Contents | Destination |
|---|---|---|
| `dce42a2` | `APT_SNAPSHOT` in `build.yml`, `release.yml`, `images/runtime/Dockerfile` | **never merges** |
| `b114252` | `contents: write` fix + its regression test | **cherry-pick to `main`** |
| `01d0043` | this document + the §9.3 correction | **cherry-pick to `main`** |
| `6e0801f` | `8.3` marked `deprecated` in `config/images.yml` | **never merges** — deprecating a PHP version is a product decision, not a test artefact |
| `90ce5b4` | `--ignore-unfixed` removed from the gate | **never merges** |
| `9812e6c` | revert of `90ce5b4` | **never merges** — pairs with it |

Only `b114252` and `01d0043` leave this branch:

```bash
git switch -c m5-gate2-land origin/main
git cherry-pick b114252 01d0043
```

**Verified, not assumed.** Both applied to a scratch worktree cut from
`origin/main` with zero conflicts; on the result 304/304 unit tests pass,
`actionlint` and `hadolint` are clean, and
`grep -rn "APT_SNAPSHOT\|snapshot.debian.org" .github/ images/ tests/ bin/`
returns nothing — the simulation leaves no trace in code. The permission
regression test passes against `main`'s `release.yml` specifically, which is
the file it reads.

`config/images.yml` on `main` still lists all three versions as `supported`;
the 8.3 deprecation exists only on this branch.

**The runtime contract was not touched.** `git diff main...m5-gate2 --
tests/structure/` is empty; the only `images/` change is the simulation `ARG`,
which leaves with the branch.
