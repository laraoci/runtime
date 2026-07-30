# M2 size report - `laraoci/cli`, `laraoci/fpm`, `laraoci/builder`

Measured on **2026-07-28**, host arch `linux/amd64`, with `bin/size-check.sh`
(`docker save <ref> | gzip -c | wc -c`, MB = 1,000,000 bytes) - the same tool and
the same units as `docs/size-report-m1.md`, so the numbers are comparable across
milestones. It approximates registry-compressed size rather than reproducing it;
the budgets are frozen against this yardstick. M4 revisits it once
`imagetools inspect` has a pushed image to look at.

`runtime` was re-measured on the same day and reproduced M1's figures exactly, so
the deltas below are like-for-like rather than a comparison against numbers taken
a day earlier on a different tree.

## Measurements

| Image     | 8.3    | 8.4    | 8.5    |
|-----------|--------|--------|--------|
| `runtime` | 227.55 | 230.53 | 232.62 |
| `cli`     | 227.55 | 230.53 | 232.62 |
| `fpm`     | 228.02 | 230.99 | 233.08 |
| `builder` | 294.03 | 297.00 | 299.11 |

Compressed MB. Every image grows monotonically with the PHP minor, so 8.5 sets
each budget - the same pattern M1 recorded, and a future 8.6 should be expected
to raise all four.

## What each image adds over `runtime`

| Image     | 8.3    | 8.4    | 8.5    |
|-----------|--------|--------|--------|
| `cli`     | 0.00   | 0.00   | 0.00   |
| `fpm`     | +0.47  | +0.46  | +0.46  |
| `builder` | +66.48 | +66.47 | +66.49 |

The deltas are constant across PHP versions to within 0.01 MB, which is the
sanity check that they measure the images' own content and not version drift.

## Budgets

Formula, unchanged from M1 and applied identically to all three:

```
ceil(max(8.3, 8.4, 8.5) x 1.10 / 5) x 5
```

| Image     | max    | x 1.10 | Budget  | Placeholder it replaced |
|-----------|--------|--------|---------|-------------------------|
| `cli`     | 232.62 | 255.88 | **260** | 225                     |
| `fpm`     | 233.08 | 256.39 | **260** | 235                     |
| `builder` | 299.11 | 329.02 | **330** | 500                     |

Committed as `size_budgets` in `config/images.yml`. The 10 % headroom absorbs
Debian package drift between the weekly rebuilds of §9.3; the rounding to 5 MB
keeps the committed number readable.

**All three placeholders were wrong, and two were wrong in the direction that
cannot happen.** `cli` at 225 and `fpm` at 235 sat below the 260 of the parent
they descend from - impossible by construction, since neither image removes
anything. `builder` at 500 was 170 MB of slack, which is not a budget.

**`cli` and `fpm` landing on `runtime`'s own 260 is the correct outcome**, not a
copy-paste error. Both add far less than the 5 MB rounding step, so all three
round identically.

## `cli` - zero bytes, verified as zero

`cli` adds `ENV` and `CMD` and nothing else. That is not an estimate: the image
has the **same 20 layer diff IDs as `runtime`, in the same order**, so its
filesystem is bit-identical and the only difference is the config blob.

```
docker image inspect ghcr.io/laraoci/runtime:8.4-trixie --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
docker image inspect ghcr.io/laraoci/cli:8.4-trixie     --format '{{range .RootFS.Layers}}{{println .}}{{end}}'
# identical
```

The three measurements matching `runtime`'s to the last significant figure is a
consequence of that, not a coincidence worth checking twice.

## `fpm` - 0.47 MB, and only a quarter of it is the package

Uncompressed layer sizes over `runtime`, from `docker history`:

| Layer                                                           | Bytes        |
|-----------------------------------------------------------------|--------------|
| RUN 1 - `apt-get install libfcgi-bin`, pre-create the pool file | 1.97 MB      |
| `COPY` the pool template                                        | 3.17 kB      |
| RUN 2 - render + `php-fpm -tt` audit                            | 4.3 kB       |
| **Total uncompressed**                                          | **~1.98 MB** |
| **Compressed delta**                                            | **0.47 MB**  |

The packages themselves are tiny:

| Package       | Installed KB |
|---------------|--------------|
| libfcgi0t64   | 92           |
| libfcgi-bin   | 41           |
| **Total**     | **133 KB**   |

**The apt transaction costs about fifteen times what the packages do.** 133 KB of
`cgi-fcgi` and its library land in a 1.97 MB layer, because `dpkg` rewrites
`/var/lib/dpkg/status` in full and the layer captures the whole rewritten file
plus the per-package `info` entries. `rm -rf /var/lib/apt/lists/*` in the same
`RUN` keeps the lists out, but nothing can keep the status database out - it is a
modified file, and a modified file is copied whole into the layer.

Worth knowing before the next image adds "just one small package": the floor for
any apt transaction in this graph is roughly 0.5 MB compressed regardless of what
is installed. §7.3's ~200 KB estimate was right about `libfcgi` and wrong about
the layer, by a factor of ten.

## `builder` - 66.5 MB, and `node` is two thirds of it

Uncompressed layer sizes over `runtime`:

| Layer                                                  | Bytes       |
|--------------------------------------------------------|-------------|
| `COPY --from=node` `/usr/local/bin/node`               | 124 MB      |
| RUN 1 - `apt-get install git unzip`, shims, cache dirs | 38.8 MB     |
| `COPY --from=node` `/usr/local/lib/node_modules`       | 12.6 MB     |
| `COPY --from=composer` `/composer`                     | 3.64 MB     |
| **Total uncompressed**                                 | **~179 MB** |
| **Compressed delta**                                   | **66.5 MB** |

Versions measured: node v24.18.0, npm 11.16.0, Composer 2.10.2, git 2.47.3.

Packages the apt transaction added, over `runtime`'s set:

| Package                    | Installed KB                       |
|----------------------------|------------------------------------|
| git                        | 49,154                             |
| git-man                    | 2,251                              |
| libcurl3t64-gnutls         | 997                                |
| unzip                      | 387                                |
| libngtcp2-16               | 335                                |
| libngtcp2-crypto-gnutls8   | 80                                 |
| liberror-perl              | 71                                 |
| **Total**                  | **53,275 KB (~53.3 MB installed)** |

`git` alone is 49 MB installed - more than `composer` and `npm` combined. It is
not optional: it is composer's VCS path, taken by any `require` on a repository
and by any package whose dist download is unavailable. `git-man` could in
principle go, but 2.25 MB installed is roughly 0.8 MB compressed, and deleting
files from a package inside the same layer is the kind of cleverness that breaks
quietly on the next base bump.

**The single largest item in the image is the `node` binary at 124 MB
uncompressed**, which is a static build with V8, ICU and its own OpenSSL inside
it. It is also the best-compressing: 124 MB of it plus 12.6 MB of `node_modules`
plus 3.64 MB of composer plus 38.8 MB of apt - 179 MB - arrives as 66.5 MB, a
2.7:1 ratio.

### The G1.7 estimate was low

The plan predicted `builder` at **~255-275 MB compressed**, with a likely budget
of 300-320. Measured: **294.03 / 297.00 / 299.11**, budget **330**.

The error is in the node line of the estimate, which read "node + npm (~30-45 MB
installed)". The real figure is 137 MB uncompressed for the two together - node
ships as one large static binary rather than the dynamically-linked, shared-libs
layout the estimate assumed. Everything else in the prediction held: composer
came in at 3.64 MB against "~3 MB", and git + unzip at 38.8 MB of layer against
"~25 MB installed" (the same units confusion noted below - 53.3 MB by
`Installed-Size`, 38.8 MB as a layer).

The budget still has 10 % headroom over the measured maximum, so nothing needs
re-planning; the estimate is recorded as wrong so the next one starts from
measurement rather than from this one.

## Observation: every image carries a full GCC toolchain

Not an M2 change, and not something M2 introduced - but it surfaced while
verifying `builder`'s documented limitation, and it is the largest single fact
about these images' size.

The official `php:8.x-fpm-trixie` base installs `$PHPIZE_DEPS` and never removes
them, so consumers can run `docker-php-ext-install`. That means **`gcc`, `g++`,
`make`, `autoconf`, `re2c`, `binutils` and their development headers are present
in `runtime`, `cli`, `fpm` and `builder` alike** - including the two images that
serve production traffic.

`gcc-14-x86-64-linux-gnu` is the **largest package in the image at 68.5 MB
installed**, ahead of `libicu76` at 37.4 MB. The toolchain closure:

| Group                                                             | Installed KB                         |
|-------------------------------------------------------------------|--------------------------------------|
| gcc / g++ / cpp 14 (incl. the `-x86-64-linux-gnu` variants)       | 140,792                              |
| libstdc++-14-dev, libgcc-14-dev                                   | 39,422                               |
| binutils (incl. libbinutils, libctf, libgprofng, libsframe)       | 30,220                               |
| sanitiser runtimes (asan, tsan, lsan, ubsan, itm)                 | 26,718                               |
| libc6-dev, linux-libc-dev, libc-dev-bin                           | 23,576                               |
| re2c                                                              | 16,630                               |
| autoconf, m4, make, dpkg-dev, pkg-config                          | 6,400                                |
| libcc1-0                                                          | 140                                  |
| **Total**                                                         | **283,898 KB (~283.9 MB installed)** |

That is more installed weight than the entire compressed image. **The compressed
saving is NOT measured here** - installed and compressed are different units and
this report does not mix them - but at the 2.7:1 ratio observed elsewhere in this
document it would plausibly be a large fraction of the 232 MB budget.

Two things make this a decision rather than a cleanup:

1. Removing `$PHPIZE_DEPS` breaks `docker-php-ext-install` for every consumer who
   extends a LaraOCI image to add an extension - a documented capability of the
   upstream base that our images inherit and that §14 implicitly relies on.
2. A compiler in a production runtime is exactly the surface D21 (no `procps`)
   and §7.1 (remove `install-php-extensions`) exist to reduce, and it is far
   larger than either of those.

**Recommended as a follow-up issue, not an M2 change.** The measurement method is
already established: a probe Dockerfile in the M1 shape (`tests/probe/`),
identical to `images/runtime/Dockerfile` except for the purge, measured with
`bin/size-check.sh`. Note M1's warning applies with full force here -
`--auto-remove` will not reclaim these, because the base marked them manually
installed; the package set must be named explicitly, and the list above is the
starting point.

## Method notes for whoever repeats this

- Three different units appear in this document, and they do not convert into one
  another. **Compressed MB** (`bin/size-check.sh`) is what the budget is in.
  **Layer bytes** (`docker history`) is what an instruction adds, uncompressed.
  **Installed-Size** (`dpkg-query -Wf '${Installed-Size}'`) is package metadata
  and matches neither - for `builder`'s apt transaction it reads 53.3 MB against
  a 38.8 MB layer. Each table above is labelled; do not mix them.
- `docker images` reports uncompressed size and will not match a budget at all.
- `LARAOCI_TAG=<php>-trixie bin/size-check.sh --image <name>` targets the same ref
  the build tags. Without `--report` it exits 1 on an overrun, which is the form
  the release path uses; with `--report` it always exits 0, which is the form PRs
  use.
- To prove an image adds no bytes, compare `.RootFS.Layers` rather than trusting
  the measurement - identical diff IDs are conclusive where two equal numbers are
  only suggestive.
