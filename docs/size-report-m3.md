# M3 size report - `laraoci/queue`, `laraoci/scheduler`, and the preload script

Measured on **2026-07-31**, host arch `linux/amd64`, with `bin/size-check.sh`
(`docker save <ref> | gzip -c | wc -c`, MB = 1,000,000 bytes) - the same tool and
the same units as `docs/size-report-m1.md` and `docs/size-report-m2.md`, so the
numbers are comparable across milestones. It approximates registry-compressed
size rather than reproducing it; the budgets are frozen against this yardstick.
M4 revisits it once `imagetools inspect` has a pushed image to look at.

`runtime` and `cli` were re-measured on the same day, because M3 changed
`runtime` - D30 added `config/php/preload.php` to it, so every image in the graph
carries a file it did not carry at M2. The deltas below are therefore
like-for-like rather than a comparison against a tree that no longer exists.

## Measurements

| Image       | 8.3    | 8.4    | 8.5    |
|-------------|--------|--------|--------|
| `runtime`   | 227.56 | 230.55 | 232.65 |
| `cli`       | 227.58 | 230.56 | 232.66 |
| `queue`     | 227.58 | 230.55 | 232.66 |
| `scheduler` | 227.57 | 230.55 | 232.66 |

Compressed MB. `fpm` and `builder` are unchanged by this milestone beyond the
preload script they inherit, and were not re-measured; M2's figures stand.

The spread across these four is **at most 0.02 MB** on any single PHP version
(0.02 on 8.3, 0.01 on 8.4 and 8.5) - under one hundredth of one percent. That is
the measurement's own noise floor, not a signal (see *Method notes* below).

## What each image adds over its parent

| Image       | Parent    | 8.3   | 8.4   | 8.5   |
|-------------|-----------|-------|-------|-------|
| `queue`     | `cli`     | 0.00  | -0.01 | 0.00  |
| `scheduler` | `cli`     | -0.01 | -0.01 | 0.00  |

**Zero, as designed, and the negative numbers are the proof rather than a
problem.** A child image cannot be smaller than its parent: it is the parent's
layers plus its own. `queue` adds one `ENV` and one `CMD`; `scheduler` adds a
`CMD` alone. Both are image-config metadata - they create no filesystem layer at
all, so the tarball `docker save` produces is byte-identical in content and
differs only in a few hundred bytes of JSON. gzip does not compress two such
tarballs to exactly the same length, and the sign of the difference is arbitrary.

Anything other than ~0.00 here would mean one of these three-line Dockerfiles had
gained something it has no business gaining, which is why the number is worth
recording rather than assuming.

## Budgets

One formula, unchanged from M1 and M2:

```
ceil(max(8.3, 8.4, 8.5) x 1.10 / 5) x 5
```

| Image       | max    | x1.10  | -> budget |
|-------------|--------|--------|-----------|
| `queue`     | 232.66 | 255.93 | **260**   |
| `scheduler` | 232.66 | 255.93 | **260**   |

Both land on `runtime`'s own 260, exactly as `cli` and `fpm` did at M2. Five of
the six budgets in `config/images.yml` are now the same number, and that is the
correct outcome for a single-rooted graph whose leaves add configuration rather
than content - not a copy-paste error.

**Both replaced a `225` placeholder that was below the parent they descend from,
which is impossible by construction.** That impossibility was deliberate: the
placeholders reported `OVER` the moment each image was first built, which is the
reminder they existed to be. Recorded here because the mechanism worked and is
worth keeping for whoever adds the next image:

```
queue      225.00  227.58  +2.58  OVER     <- before
queue      260.00  227.58  -32.42 ok       <- after
```

With this milestone, **no placeholder survives in `size_budgets`**.

## The preload script's cost across the whole graph

D30 puts `config/php/preload.php` in `runtime`, so all six images carry it. It is
**6,667 bytes on disk**, verified identical inside the built image:

```
$ wc -c config/php/preload.php
6667
$ docker run --rm --entrypoint sh ghcr.io/laraoci/queue:8.4-trixie -c \
    'wc -c < /usr/local/share/laraoci/preload.php'
6667
```

Re-measured against M2's frozen figures, `cli` reads **0.03-0.04 MB higher**:

| Image | M2 (2026-07-28) | M3 (2026-07-31) | Δ    |
|-------|-----------------|-----------------|------|
| `cli` | 227.55 / 230.53 / 232.62 | 227.58 / 230.56 / 232.66 | +0.03 / +0.03 / +0.04 |

**That delta is larger than the file, and the file is not all of it.** 6.7 KB of
PHP compresses to roughly 2 KB, so at most a fifteenth of the 30-40 KB observed.
The remainder is layer overhead - the `COPY` adds a layer with its own tar
headers and metadata, and RUN 4 changed, so its layer was rebuilt against
whatever Debian packages the base carried on the day. The two effects cannot be
separated by this measurement and are not worth separating: the total is three
orders of magnitude inside the 5 MB rounding step and moves no budget.

M2's `cli` row in `config/images.yml` is deliberately **not** rewritten. It is
that milestone's frozen record; this file carries the re-measurement.

## Method notes for whoever repeats this

- **Rebuild before measuring.** M3 changed `runtime` twice (D30's `COPY`, then
  LOCI-035's `ENV` block), and every descendant is stale until rebuilt. A budget
  frozen against a stale image is a wrong number that looks authoritative. Every
  figure above was taken after `bin/build-chain.sh` rebuilt the full chain for
  that version.
- **`docker save | gzip` is not deterministic to the byte.** Repeated runs on an
  unchanged image differ in the tens of kilobytes. Treat anything under ~0.1 MB
  as noise; that is why the 10% headroom and the 5 MB rounding exist.
- **The enforcing path needs every image present.** `bin/size-check.sh` without
  `--report` exits 1 on a `MISSING` row, by design - a size that was never
  measured must not read as a pass. On a developer machine that has not built the
  whole graph for a version, expect `MISSING` for `fpm` and `builder` and read it
  as "not built here", not as a regression.
- Per-image measurement is `LARAOCI_TAG=<php>-trixie bin/size-check.sh --image
  <name> --report`. Without `LARAOCI_TAG` the tag is derived from the version
  carrying `default: true`.
