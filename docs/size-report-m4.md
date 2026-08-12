# M4 size report - the first arm64 measurements

Measured on **2026-08-11** from release run
[`31484096613`](https://github.com/laraoci/runtime/actions/runs/31484096613), a
🚦 Gate 2 staging run against `ghcr.io/laraoci/laraoci-staging`. **All 36 build
legs green, every size row `ok`.**

Instrument: `bin/size-check.sh` - `docker save <ref> | gzip -c | wc -c`,
MB = 1,000,000 bytes. **Unchanged from M1, M2 and M3 on purpose** (D39). A
registry layer-sum is arguably truer and is a *different number*; enforcing a
budget frozen with one instrument using a measurement from another turns a clean
build into a spurious release block.

Every figure below was taken by the release path itself, against the **pushed
digest**, on a runner native to the architecture it reports - `ubuntu-24.04` for
amd64, `ubuntu-24.04-arm` for arm64. Nothing here was built under emulation
(D3a), and nothing was measured on a load-path rebuild.

## Why this milestone measures anything at all

Every budget in `config/images.yml` was frozen on **`linux/amd64` alone** -
`runtime` on 2026-07-27, `cli`/`fpm`/`builder` on 2026-07-28, `queue`/`scheduler`
on 2026-07-31. No image in this repository had ever been measured on arm64,
because until M4 no arm64 image existed.

M4 changed two things at once: it builds arm64 natively, and it makes the size
check **enforcing** on the release path (§9.2, D17) - no `--report`, exit 1 on an
overrun. So a budget frozen against one architecture began gating the other on
the same run.

**`size_budgets` is one scalar per image, not one per architecture.** `runtime:
260` gates both legs identically, so the larger architecture sets the budget.

**That risk is now retired: arm64 is smaller than amd64 on every image.**

## Measurements - `linux/arm64`

| Image       | 8.3    | 8.4    | 8.5    |
|-------------|--------|--------|--------|
| `runtime`   | 216.95 | 219.57 | 221.58 |
| `cli`       | 216.96 | 219.57 | 221.58 |
| `fpm`       | 217.19 | 219.82 | 221.82 |
| `builder`   | 296.17 | 298.81 | 300.79 |
| `queue`     | 216.96 | 219.59 | 221.58 |
| `scheduler` | 216.95 | 219.58 | 221.58 |

## Measurements - `linux/amd64`, re-measured

Taken on the same run, not copied from the frozen table - `builder` changed since
it was frozen (D42's npm upgrade), so a comparison against 2026-07-28 numbers
would not be like-for-like.

| Image       | 8.3    | 8.4    | 8.5    |
|-------------|--------|--------|--------|
| `runtime`   | 227.57 | 230.55 | 232.65 |
| `cli`       | 227.57 | 230.55 | 232.66 |
| `fpm`       | 227.80 | 230.81 | 232.90 |
| `builder`   | 307.22 | 310.19 | 312.29 |
| `queue`     | 227.57 | 230.56 | 232.64 |
| `scheduler` | 227.57 | 230.56 | 232.66 |

### Drift against the frozen amd64 rows

| Image       | 8.3             | 8.4             | 8.5             |
|-------------|-----------------|-----------------|-----------------|
| `runtime`   | 227.57 (-0.03)  | 230.55 (+0.05)  | 232.65 (+0.05)  |
| `cli`       | 227.57 (+0.02)  | 230.55 (+0.02)  | 232.66 (+0.04)  |
| `fpm`       | 227.80 (-0.22)  | 230.81 (-0.18)  | 232.90 (-0.18)  |
| `builder`   | 307.22 (+13.19) | 310.19 (+13.19) | 312.29 (+13.18) |
| `queue`     | 227.57 (-0.01)  | 230.56 (+0.01)  | 232.64 (-0.02)  |
| `scheduler` | 227.57 (+0.00)  | 230.56 (+0.01)  | 232.66 (+0.00)  |

Five images are within ±0.05 MB - gzip noise, three orders of magnitude inside
the 5 MB rounding step, and confirmation that the instrument still reports what
it reported three weeks ago.

Two rows are not noise:

- **`fpm` is 0.18-0.22 MB smaller** than frozen, consistently across all three
  versions. Above the ~0.1 MB noise floor, so real, and a *decrease* - Debian
  package drift in `libfcgi-bin`/`libfcgi0t64` between 2026-07-28 and now. It
  moves nothing and is recorded only so the next reader does not re-derive it.
- **`builder` is +13.19 MB**, and the consistency across 8.3/8.4/8.5 to within
  0.01 MB is the tell: a fixed-size addition, not drift. That is **D42's npm
  12.0.2 upgrade**, which replaces npm's bundled dependency tree to clear a
  CRITICAL node-tar gzip bomb. See the budget section - it is the one number in
  this report with a consequence.

## arm64 against amd64

| Image       | amd64 max | arm64 max | Δ      | larger arch |
|-------------|-----------|-----------|--------|-------------|
| `runtime`   | 232.65    | 221.58    | -11.07 | amd64       |
| `cli`       | 232.66    | 221.58    | -11.08 | amd64       |
| `fpm`       | 232.90    | 221.82    | -11.08 | amd64       |
| `builder`   | 312.29    | 300.79    | -11.50 | amd64       |
| `queue`     | 232.64    | 221.58    | -11.06 | amd64       |
| `scheduler` | 232.66    | 221.58    | -11.08 | amd64       |

**arm64 is smaller on every image, by a near-constant 11.06-11.50 MB.** The
uniformity across six images and three PHP versions says this is one shared
cause in the base layer - arm64 object code for the same package set, not
anything LaraOCI installs. `builder`'s slightly larger gap (-11.50) is the only
one that differs, and it is the only image adding a second toolchain on top.

**Consequence: amd64 sets every budget.** The formula's "larger architecture"
clause resolves to amd64 in all six cases, which is the architecture the budgets
were already frozen against - so arm64 enforcement introduces no new risk. That
is the question this report was written to answer.

## Budgets - does anything have to move?

One formula, unchanged from M1, M2 and M3, applied to the larger architecture:

```
ceil(max(8.3, 8.4, 8.5, across BOTH architectures) x 1.10 / 5) x 5
```

| Image       | max (either arch) | x1.10  | -> formula | frozen | moves?         |
|-------------|-------------------|--------|------------|--------|----------------|
| `runtime`   | 232.65            | 255.92 | 260        | 260    | no             |
| `cli`       | 232.66            | 255.93 | 260        | 260    | no             |
| `fpm`       | 232.90            | 256.19 | 260        | 260    | no             |
| `builder`   | 312.29            | 343.52 | **345**    | 330    | **yes, ->345** |
| `queue`     | 232.64            | 255.90 | 260        | 260    | no             |
| `scheduler` | 232.66            | 255.93 | 260        | 260    | no             |

**No budget was exceeded.** Every one of the 36 legs reported `ok`, `builder`
included - 312.29 against 330 is a pass with 17.71 MB to spare.

**But `builder`'s budget no longer carries the headroom the formula intends.**
That distinction is the whole finding, so it is worth stating precisely:

- The gate is *not* failing and nothing is blocked.
- The formula on today's measurement yields **345**, not the frozen 330.
- At 330, `builder` has **5.7%** headroom over its largest build. The formula
  exists to leave **10%**, which is what absorbs Debian package drift between
  the weekly rebuilds (§9.3).

So `builder` is one ordinary base bump away from a release blocked by a budget
that was correct when it was frozen and stopped being correct when D42 added
13 MB. Re-freezing to 345 restores the intended margin.

**Decided: re-frozen to 345**, in `config/images.yml`, on 2026-08-11. The
alternative reading was considered and rejected - that 330 passes today and a
budget which only ever moves upward stops being a budget. It loses because the
+13.19 MB is not drift: it is a deliberate, identified, fixed-size addition
(D42's npm upgrade, consistent to 0.01 MB across three versions), and the 10%
margin exists to absorb *unplanned* Debian movement between weekly rebuilds
(§9.3). Spending it on a change we chose leaves nothing for the ones we do not.

**Re-frozen by the formula, not nudged to the smallest passing value.** 345 is
`ceil(312.29 x 1.10 / 5) x 5`. Picking, say, 335 would fit the budget to the
build rather than to the formula and spend the headroom silently - which is the
failure this rule exists to prevent.

**If D42 is later reverted** - because a fixed upstream npm bundle makes the
in-place upgrade unnecessary - `builder` returns to ~299 and 345 becomes too
generous. Re-run the formula then; a budget that is too loose is a gate that has
stopped gating.

## Method notes

- **`docker save | gzip` is not deterministic to the byte.** Repeated runs on an
  unchanged image differ in the tens of kilobytes. Treat anything under ~0.1 MB
  as noise - that is what the 10% headroom and the 5 MB rounding absorb. The
  ±0.05 MB drift on five images above is exactly this; `fpm`'s -0.20 and
  `builder`'s +13.19 are not.
- **The enforcing path needs every image present.** `bin/size-check.sh` without
  `--report` exits 1 on a `MISSING` row by design: a size that was never measured
  must not read as a pass.
- **Do not measure arm64 under emulation.** A QEMU-built image is a different
  artifact, and D3a forbids it precisely so no number here came from one.

### Reproducing these numbers

`gh run view --log` on the whole run fails with *too many API requests* - 58 jobs
is past what it will fetch. Go per job:

```bash
RUN=31484096613

# job ids, with image/php/platform in the name
gh run view "$RUN" --json jobs \
  --jq '.jobs[] | select(.name|test("build-d")) | "\(.databaseId)\t\(.name)"'

# the size row from one leg - step names render as "UNKNOWN STEP" in the log,
# so match the OUTPUT, not the step
gh run view "$RUN" --job <JOB_ID> --log | grep -E '^\S*\s+runtime\s+[0-9]+\.[0-9]{2}'
```

The rows look like this:

```
IMAGE         BUDGET_MB  ACTUAL_MB   DELTA_MB  STATUS
runtime          260.00     232.65     -27.35  ok
```

Locally, against an explicit reference - the form the release path uses:

```bash
bin/size-check.sh --image <name> --ref <registry>/<name>@sha256:<digest>
```
