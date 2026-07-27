# M1 size report - `laraoci/runtime`

Measured on **2026-07-27**, host arch `linux/amd64`, with `bin/size-check.sh`
(`docker save <ref> | gzip -c | wc -c`, MB = 1,000,000 bytes). This approximates
registry-compressed size rather than reproducing it; the budget is frozen
against this tool so the yardstick stays consistent. M4 revisits it once
`imagetools inspect` has a pushed image to look at.

| PHP | Compressed MB |
|-----|---------------|
| 8.3 | 227.6         |
| 8.4 | 230.5         |
| 8.5 | 232.6         |

**Budget:** `ceil(max(227.6, 230.5, 232.6) x 1.10 / 5) x 5` = **260 MB**,
committed as `size_budgets.runtime` in `config/images.yml`. The 10 % headroom
absorbs Debian package drift between the weekly rebuilds of §9.3; the rounding
keeps the committed number readable.

**The §5 placeholder of 220 MB was already too low** - every supported version
exceeds it before `cli`, `fpm` or `builder` add anything. Growth is monotonic
with the PHP minor (227.6 -> 230.5 -> 232.6), so 8.5 sets the budget and a future
8.6 should be expected to push it further.

## Ghostscript purge (LOCI-014)

Removed as a unit inside RUN 1: `ghostscript`, `libgs10`, `libgs10-common`,
`libgs-common`, `poppler-data`.

| Package        | Installed KB                       |
|----------------|------------------------------------|
| libgs10        | 22,216                             |
| poppler-data   | 13,086                             |
| libgs10-common | 2,265                              |
| libgs-common   | 316                                |
| ghostscript    | 183                                |
| **Total**      | **38,066 KB (~38.1 MB installed)** |

`fonts-urw-base35` (15,560 KB) is deliberately **retained**: it is a Recommends
of `libmagickcore-7.q16-10`, i.e. ImageMagick's standard PostScript-35 font set,
not Ghostscript baggage. Removing it would break text annotation for anyone not
naming a font explicitly.

**§3.2 is wrong about the mechanism.** It states that `--auto-remove` reclaims
the orphaned tree. It does not: `install-php-extensions` marks everything it
pulls in as *manually* installed, and `--auto-remove` only reclaims *auto*-marked
packages. `apt-get purge -y --auto-remove ghostscript` on its own frees **187 kB**
and leaves the other 38 MB in place. The tree must be named explicitly.

## `libmagickcore-*-extra` (spec §17 q3, feeds LOCI-056)

Method: two builds from `tests/probe/no-extra.Dockerfile`, identical except for
`--build-arg PURGE_EXTRA`, so the delta contains nothing but the package. An
earlier attempt diffed a probe against the real image and produced a *negative*
result, because the probe's Ghostscript purge had drifted from RUN 1, and it
still carried 38 MB of libgs.

| Variant          | Compressed MB   |
|------------------|-----------------|
| with `-extra`    | 230.52          |
| without `-extra` | 230.44          |
| **contribution** | **0.08 MB**     |

**The size premise behind the `-slim` idea does not hold.** §3.2 assumes the
`-extra` codec package "brings DjVu, WMF, OpenEXR, and RAW decoders - more size
and more parser surface than a Laravel app typically needs". The parser-surface
half stands. The size half does not: `libmagickcore-7.q16-10-extra` is a **295 KB**
shim of coder modules.

The decoders themselves arrive as its *dependencies*, and they survive
`apt-get purge --auto-remove libmagickcore-*-extra` for exactly the reason the
Ghostscript tree did - they are marked manual. Depended on by `-extra` alone:

| Package           | Installed KB                     |
|-------------------|----------------------------------|
| libopenexr-3-1-30 | 6,288                            |
| libdjvulibre21    | 1,837                            |
| libdjvulibre-text | 340                              |
| libwmflite-0.2-7  | 202                              |
| **Total**         | **8,667 KB (~8.7 MB installed)** |

A wider sweep including decoders owned by ImageMagick *core* rather than
`-extra` (`libraw23t64`, `libheif1`, `libopenjp2-7` and the libheif plugins)
reaches 13,475 KB (~13.5 MB installed). Those are not `-extra`'s to give back.

**Reading for LOCI-056:** a `-slim` variant is **not justified on size grounds**.
Purging `-extra` reclaims 0.08 MB as measured; purging it together with its
exclusive dependencies would reclaim single-digit MB, under 4 % of a 230 MB
image, and would require naming each package explicitly because `--auto-remove`
is inert here. The 70-100 MB that imagick costs (§3.2) is ImageMagick proper,
not the `-extra` package. If `-slim` is ever revisited it should be argued on
CVE/parser surface, with these numbers stated so nobody expects a size win.

## Method notes for whoever repeats this

- Measure with `bin/size-check.sh`, not `docker images` - the latter reports
  uncompressed size and will not match the budget at all.
- `LARAOCI_TAG=<php>-trixie bin/size-check.sh --image runtime` targets the same
  ref the build tags.
- Any probe used for a delta must mirror RUN 1 of `images/runtime/Dockerfile`.
  When RUN 1 changes, `tests/probe/no-extra.Dockerfile` changes with it, or the
  delta quietly stops describing the shipped image.
- Installed size (`dpkg-query -Wf '${Installed-Size}'`) and compressed size are
  different units and are labelled as such throughout. Do not mix them.
