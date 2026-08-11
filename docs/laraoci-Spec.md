# LaraOCI - Architecture & Implementation Specification

**Status:** Draft v2 · Spec-first, pre-implementation
**Scope:** Image catalog, runtime contract, build pipeline, supply chain, release policy

---

## 1. Vision

LaraOCI provides production-ready OCI images for Laravel applications that are secure, lightweight, well-maintained, and easy to deploy.

Instead of every Laravel project maintaining its own Dockerfiles, LaraOCI publishes a curated set of images that encode Laravel and container best practices. Deploying a Laravel application should mean choosing the right image and supplying application code.

**The contract with consumers:** *you bring `vendor/` and your code; we bring a correct PHP runtime, correct signal handling, correct logging, and a maintained security posture.*

---

## 2. Design Principles

### 2.1 Production first

Secure defaults, minimal attack surface, non-root execution, tuned PHP configuration. Nothing in a runtime image exists unless a production Laravel workload needs it.

### 2.2 Reusable layers

All images descend from a single shared runtime layer. Divergence is limited to the process an image runs and the tools that process requires.

```
                    php:X.Y-fpm-trixie       (official upstream)
                              │
                              ▼
                     laraoci/runtime          (shared layer, published)
        ┌─────────────┬───────┴───────┬───────────────┐
        │             │               │               │
        ▼             ▼               ▼               ▼
  laraoci/cli   laraoci/fpm    laraoci/builder   (future variants)
        │
   ┌────┴─────┐
   ▼          ▼
 queue    scheduler          (CMD-only derivatives of cli)
```

> **Correction to the original draft:** FPM branches from `runtime`, not from `queue`. FPM is a sibling of CLI, not a descendant of a worker image.

### 2.3 Configuration over duplication

PHP versions, Debian releases, extension sets, and image types live in `config/images.yml`. CI derives the build matrix from that file. Adding a PHP version is a one-file change; no workflow edits.

### 2.4 Immutable, not "reproducible"

`apt-get` against moving mirrors cannot produce bit-identical images. LaraOCI does not claim bit reproducibility. It claims **immutability and verifiability**: every published artifact is addressable by digest, carries an SBOM and build provenance, and is signed.

---

## 3. Decision Register

| #       | Decision                                                                                 | Rationale                                                                                                                                                                                                                                                                                                                                    |
|---------|------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| D1      | FPM inherits from `runtime`, not `queue`                                                 | FPM and CLI are siblings; the original graph was a transcription error                                                                                                                                                                                                                                                                       |
| D2      | The shared layer is named `runtime` and is **published**                                 | Users with unusual needs extend rather than fork; `base` read as internal-only                                                                                                                                                                                                                                                               |
| D3      | A `builder` image ships in v1, **multi-arch**                                            | `vendor/` must come from somewhere; ARM matters for Apple Silicon local builds (revised - see D3a)                                                                                                                                                                                                                                           |
| D4      | `queue` and `scheduler` ship as `FROM cli` + `CMD` only                                  | Near-zero marginal cost, room to diverge later                                                                                                                                                                                                                                                                                               |
| D5      | **One Debian release across the entire matrix** - `trixie`                               | Collapses the OS axis to a constant; see §3.1                                                                                                                                                                                                                                                                                                |
| D6      | Composer is **absent** from `cli`, `fpm`, `queue`, `scheduler`                           | Attack surface; those images run application code, not dependency resolution                                                                                                                                                                                                                                                                 |
| D7      | Node/Vite tooling lives only in `builder`                                                | Same reasoning as D6                                                                                                                                                                                                                                                                                                                         |
| D8      | Fixed UID/GID `1000:1000`, user `laravel`, across all images                             | Shared `storage/` volumes; mismatched ownership is the #1 support burden                                                                                                                                                                                                                                                                     |
| D9      | `tini` as init in every image                                                            | Zombie reaping and signal forwarding, independent of `--init`                                                                                                                                                                                                                                                                                |
| D10     | Scheduler uses `schedule:work`, not cron                                                 | Container-native, single foreground process, logs to stdout                                                                                                                                                                                                                                                                                  |
| D11     | JIT disabled by default                                                                  | Neutral-to-negative for typical FPM/Laravel workloads                                                                                                                                                                                                                                                                                        |
| D12     | Extensions installed via `docker-php-extension-installer`                                | Large maintenance saving over hand-rolled builds                                                                                                                                                                                                                                                                                             |
| **D13** | `imagick` included in `runtime`, with a **hardened `policy.xml`** and **no Ghostscript** | Broad demand; the delegate/coder denylist removes the entire ImageTragick-class attack surface (§3.2)                                                                                                                                                                                                                                        |
| **D14** | An opt-in **preload script** ships at a fixed path, disabled by default                  | Real gains for FPM; too failure-prone to enable blindly                                                                                                                                                                                                                                                                                      |
| **D15** | PHP **8.3, 8.4, 8.5** all `supported`                                                    | No `preview` tier at launch                                                                                                                                                                                                                                                                                                                  |
| **D16** | **FrankenPHP** is the first post-v1 variant, and is permitted a **second root layer**    | It is a SAPI, not a bolted-on web server (§3.3)                                                                                                                                                                                                                                                                                              |
| **D17** | CI enforces a **per-image size budget**                                                  | Makes "lightweight" a testable claim rather than an aspiration                                                                                                                                                                                                                                                                               |
| **D18** | `runtime` derives from the **`-fpm` upstream variant**, not `-cli`                       | The only way the single-root graph is actually achievable; the fpm variant ships the CLI binary too (§3.4)                                                                                                                                                                                                                                   |
| **D19** | `install-php-extensions` is pinned by **digest**, not by tag                             | Determinism in the one layer that decides the whole extension surface; Renovate keeps it current (§2.4)                                                                                                                                                                                                                                      |
| **D20** | The LaraOCI entrypoint **chains** `docker-php-entrypoint` rather than replacing it       | Reimplements nothing and survives a base bump. **Narrowed by D23:** the chain stays, the reliance on upstream's leading-`-` fixup does not (§6.2)                                                                                                                                                                                            |
| **D21** | `procps` is **not** installed in any image                                               | One process per container makes `ps` near-useless; `kubectl debug` covers incidents (§7.1)                                                                                                                                                                                                                                                   |
| **D22** | Preload is gated on the **SAPI** by the entrypoint, written to a separate ini            | CLI opcache is per-process, so preload taxes every `php artisan` call and persists nothing (§7.7)                                                                                                                                                                                                                                            |
| **D23** | A per-image `LARAOCI_DEFAULT_BINARY` decides what a **dash-first argument** means        | Upstream's fixup prepends `php-fpm` unconditionally, and every non-FPM image inherits that script from the `-fpm` base (D18). One variable, read once in the entrypoint, fixes both halves - which binary starts, and whether D22's gate reads the process as FPM - without a forked copy of upstream's script (§6.2, §7.2)                  |
| **D24** | A stated **boundary between structure and smoke tests**, with one deliberate exception   | "Static if it can be, behavioural only when it cannot": structure tests run on every leg in seconds, smoke tests cost minutes. `clear_env = no` is asserted twice on purpose - statically it catches upstream drift on a base bump, behaviourally it catches everything between the directive and `env()` actually returning the value (§10) |
| **D25** | `builder` returns to `USER laravel` **before** its contract `ENV`s and `CMD`             | Root is held only for the apt/symlink/mkdir block. `COMPOSER_HOME` and `NPM_CONFIG_CACHE` live under `/home/laravel`, created explicitly and owned `1000:1000`, so a mounted BuildKit cache is writable by the user that actually runs (§7.4)                                                                                                |
| **D26** | `builder` inherits the hardened `policy.xml` and the Ghostscript purge **unchanged**     | An artifact built in a weaker environment than it runs in is the classic production-only surprise; `builder` is also the image most likely to meet untrusted input, since CI runs it against whatever a pull request contains (§3.2, §14)                                                                                                    |
| **D27** | A child leg **builds its own ancestor chain** into the local daemon                      | Until M4 pushes, `ghcr.io/laraoci/runtime:*` exists in no registry and every matrix leg is a separate runner. `bin/build-chain.sh` builds ancestors in topological order on the `docker` driver, whose builder *is* the daemon; the `docker-container` driver cannot see a loaded image at all. No-ops once `push: true` (§9.1)              |
| **D28** | `org.opencontainers.image.base.*` on child images is **wrong until M4** - accepted debt  | The label still names `php:<v>-fpm-<suite>` where the real base is `laraoci/runtime`. The PR path builds with `--load`, where no manifest digest exists, so M2 could not emit a truthful `base.digest` even if it corrected `base.name`. Recorded so it reads as known debt rather than as a defect discovered later (§11)                   |
| **D29** | `queue` bakes **`LARAOCI_PRELOAD_FORCE=1`** but does **not** default `PHP_OPCACHE_PRELOAD` | The force flag is the queue-specific fact - a worker compiles once and serves thousands of jobs from the warm segment - and it is safe because it is INERT until an operator names the script. Defaulting the script name too would preload a vendor tree the image cannot guarantee it has, charge every one-off `artisan` call on the image for a segment it discards at exit, and require `PHP_OPCACHE_MEMORY_CONSUMPTION=320` on every queue container whether or not it preloads (§7.5, §7.7) |
| **D30** | The preload script's `COPY` lives in **`runtime`**, not in `queue`                       | §7.1 lists it among what runtime installs. Every image then carries it inert, and `fpm` - the DEFAULT preload consumer under D22 - has it without a second copy, so the preload story is one file rather than two. Measured cost: 6,667 bytes, inside every budget's 5 MB rounding step (§7.7, `docs/size-report-m3.md`) |
| **D31** | The scheduler single-fire test **anchors a 60 s window to a minute boundary**            | `schedule:work` fires on boundaries, so a naive 70 s window spans two of them and legitimately sees two fires - which reads as a double-fire defect. Anchoring gives 5 s of margin before the tick and 55 s after. Rejected: a sub-minute cadence (counting N fires in a short window is MORE race-prone) and driving `schedule:run` in a loop (which tests a loop we wrote, not the shipped `CMD`). Measured fires land on the boundary to the second (§7.6, LOCI-037) |
| **D32** | The preload script logs through **`error_log()`**, never `fwrite(STDERR, …)`             | `STDIN`/`STDOUT`/`STDERR` are registered by the SAPI *after* opcache runs the preload script, so the v1 §7.7 listing raised `Undefined constant "STDERR"` - and an uncaught `Error` during preload **aborts startup**, taking the FPM master with it. `php://stderr` fails identically but **silently** (exit 255). `error_log()` is the only mechanism measured to survive and still reach stderr, at the cost of a `[date]` prefix. The spec's own listing is corrected; this is the milestone's spec correction (§7.7) |
| **D33** | **`/Console/` joins the default `LARAOCI_PRELOAD_IGNORE`**                               | The consequence of excluding `vendor/symfony` (§7.7), not an independent choice: without it `Illuminate\Console\Command` cannot link and ~78 command subclasses fail behind it, so the default compiled 130 classes that could never be preloaded and warned 176 times per start. Measured 2026-07-31 on a Laravel 13 tree: -131 warnings, -2.35 MB, at a cost of 80 preloaded classes that no `fpm` request and no steady-state `queue` worker touches. It belongs by the list's own logic - every other entry is a subtree off the serving hot path (§7.7) |
| **D40** | Kernel-header CVEs in `linux-libc-dev` are **suppressed with a dated expiry**, not fixed by purging the C toolchain | The vulnerability gate's first real block (🚦 Gate 2, 2026-08-11) was CVE-2026-64561 and CVE-2026-64564 - Linux **kernel** flaws (KVM, SCTP) reported against `linux-libc-dev`, the kernel *headers* package. A container runs the HOST's kernel; the headers are build-time C declarations with no code path in a running image, so neither CVE is reachable in anything LaraOCI ships. They are still suppressed rather than dismissed, because the package is genuinely removable: `linux-libc-dev` is reachable only through `libc6-dev`, so purging it takes `g++`, `libstdc++-14-dev`, `libc-dev-bin`, `libcrypt-dev` and `rpcsvc-proto` with it - a **measured 87 MB off each of the six images**, and the permanent end of a class that regenerates every time the kernel does (the base's 6.12.96-1 carried fourteen; the build's own `apt-get update` pulls it to 6.12.100-1 and fixes twelve). Deferred rather than taken, because `tests/structure/builder.yaml` records - **measured, against the doc's claim** - that the upstream base installs `$PHPIZE_DEPS` and never removes them, so a compiler is present on every image in the graph, and that §7.4's node-gyp limitation is caused by `python3` being absent alone: "a one-package fix for a consumer who needs it". Purging the toolchain makes that a multi-package fix and changes `builder`'s contract, which is a §7.4 decision with its own record - not something to slip in under a red gate. **Corrected 2026-08-11:** the entries first named "trixie publishing 6.12.101-1" as the unblock. It is already published and is apt's CANDIDATE from `trixie-security`; the image misses it because the layer that resolves it is a GHA cache hit (D41), so the blocker is cache invalidation, not upstream. **Revisit when** the suppressions reach their expiry, or when kernel-header CVEs block a second release: at that point 87 MB and the end of the class outweigh the node-gyp convenience. D38 stands - the gate keeps no base-layer exemption, and these two entries are dated and listed in the release notes |
| **D41** | The weekly rebuild (§9.3) must **invalidate the apt layer**, or it rebuilds nothing | §9.3 exists to catch "package-level updates that don't move the upstream digest" - and that is the exact case the build cache skips. `build.yml` restores layers with `cache-from: type=gha`; a layer's key is its RUN command plus its parent, and the parent is pinned by `BASE_DIGEST`, resolved from a base tag that moves only when upstream rebuilds. So when Debian ships a security update but `php:<v>-fpm-<suite>` does not move, every input to the key is unchanged: the layer is restored, `apt-get update` never executes, and a "weekly rebuild" reproduces a byte-identical image while reporting success. Found 2026-08-11 from the other end - `linux-libc-dev` sat at 6.12.100-1 in a freshly built image while 6.12.101-1 was already the candidate in `trixie-security` (D40). The scheduled path therefore cannot share the release path's cache policy unchanged. Not fixed here: M4 does not own §9.3, and the correction is a real trade - `no-cache-filters` on the extension stage, a date-valued build arg, or an explicit upgrade step each cost rebuild time on legs that currently hit cache, and the choice belongs with M5 alongside the schedule itself. Recorded now so M5 starts from the measurement rather than rediscovering it from a CVE |

### 3.4 Why `runtime` uses the `-fpm` upstream variant (D18)

The v2 draft said `fpm` would "install the FPM SAPI on top of `runtime`" so that all images share one root. **That is not implementable.** The official `php:` images compile PHP from source into `/usr/local`; there is no Debian package that adds `php-fpm` to such a build. Getting FPM onto a `-cli` base would mean recompiling PHP - an enormous and permanent maintenance commitment.

The resolution is to invert it. Inspecting `docker-library/php`, the `cli` and `fpm` Dockerfiles are the same build with different `configure` flags: `fpm` adds `--enable-fpm`, `--with-fpm-user/group`, and `--disable-cgi`, and **nothing disables the CLI SAPI**. So `php:X-fpm-trixie` ships *both* `/usr/local/sbin/php-fpm` and `/usr/local/bin/php`.

Basing `runtime` on the `-fpm` variant therefore gives a genuinely single-rooted graph with real shared layers, rather than a shared-source fiction. `fpm` supplies a pool config and a command; `cli` supplies a command.

Costs, all small and stated:

- `cli`, `queue`, `scheduler`, and `builder` carry the unused `php-fpm` binary - single-digit megabytes.
- The `fpm` variant builds with `--disable-phpdbg` and without `--enable-embed`, both of which the `cli` variant has. phpdbg is rarely used in containers; `--enable-embed` matters only for embedding SAPIs, and FrankenPHP has its own root anyway (§3.3). If either becomes load-bearing, the graph splits - but not before evidence.

### 3.1 Why one Debian for everything (D5, revising the earlier per-version pin)

The v1 draft pinned Debian per PHP version, which would have put 8.3/8.4 on bookworm and 8.5 on trixie. Supporting all three versions makes that a two-OS matrix carrying two sets of package CVEs, two glibc versions, and two ImageMagick config paths - for no consumer-visible benefit.

Bookworm's regular security support window has closed; it is now maintained by the Debian LTS team on narrower terms. A project publishing its *first* images should not launch on an OS already in LTS. Standardising on trixie collapses the axis to a constant.

The `debian` key stays in `config/images.yml` per PHP version. It is a transition mechanism, not a product axis - when trixie ages out, versions migrate individually rather than in a flag day.

**Verified.** `docker-library/php` publishes `trixie/cli`, `trixie/fpm`, `trixie/apache`, and `trixie/zts` for **every** currently-built version - 8.2, 8.3, 8.4, and 8.5 - alongside the bookworm and Alpine variants. There is no fallback case; the single-OS matrix holds.

Current upstream patch levels at time of writing: 8.3.32, 8.4.23, 8.5.8. An 8.6 alpha is already being built with full trixie coverage, so the 8.6 GA (expected late 2026) will slot into `config/images.yml` as a one-line addition.

**8.2 is deliberately excluded** despite still being built upstream. Its security window closes at the end of 2026; adding it now means adding twelve build legs and deprecating them within about five months.

### 3.2 The imagick trade (D13)

Including imagick is a real cost, stated plainly:

- **Size:** ImageMagick core plus delegates adds an estimated **70–100 MB**. Much of the delegate set (libjpeg, libpng, libwebp, libfreetype) is already present for `gd`, so the net figure is the number to measure, not the package total. **Measured and frozen in M1:** `runtime` compresses to 227.6 / 230.5 / 232.6 MB on 8.3 / 8.4 / 8.5, and `size_budgets.runtime` is committed at **260 MB** (max + 10% headroom, rounded to 5). See `docs/size-report-m1.md` for the method, the tool, and the host arch; growth is monotonic with the PHP minor, so 8.5 sets the budget.
- **CVE surface:** ImageMagick has the heaviest vulnerability history of anything in the image.

Both are mitigated rather than accepted:

**No Ghostscript - but it must be actively removed, not merely not-requested.** ImageMagick's PDF, PS, and EPS handling shells out to Ghostscript, the vector for nearly every ImageMagick RCE of the last decade.

Two facts make this a build step rather than an omission:

1. `install-php-extensions imagick` **installs `ghostscript` unconditionally on Debian** and marks it persistent. `--no-install-recommends` does not prevent this; the installer names the package directly.
2. Ghostscript is only a **Recommends** of `libmagickcore-7.q16-*`, never a Depends. Nothing breaks when it goes.

So the runtime image purges it explicitly after the extension install. The purge is a hard step with no `|| true`, and a structure test asserts `gs` is absent, so a future installer change that reorders things fails the build loudly instead of silently reintroducing the interpreter.

**`--auto-remove` does not reclaim the tree - M1 disproved that.** The installer marks everything it pulls in as *manually* installed, and `--auto-remove` only reclaims *auto*-marked packages: `apt-get purge -y --auto-remove ghostscript` on its own frees **187 kB** and leaves the rest in place. Every package must be named: `ghostscript`, `libgs10`, `libgs10-common`, `libgs-common`, `poppler-data` - **38.1 MB installed**, measured. `fonts-urw-base35` is deliberately **retained**, contrary to the earlier wording here: it is a Recommends of `libmagickcore-7.q16-10`, i.e. ImageMagick's standard PostScript-35 font set, not Ghostscript baggage, and removing it silently breaks text annotation for anyone who does not name a font explicitly.

The purge and its assertions live in the **same `RUN`** as the extension install. Docker layers are additive, so a purge in a later instruction removes the files from the final filesystem while leaving their bytes in the earlier layer's tarball - an image that passes `command -v gs` and still ships the interpreter.

PDF rasterisation is explicitly out of scope (§14). An application that needs it installs Ghostscript in its own layer, consciously.

**Hardened `policy.xml`,** shipped at build time, denying all delegates, the Ghostscript-adjacent coders, the network coders, and indirect-read paths:

```xml
<policymap>
  <policy domain="delegate" rights="none" pattern="*"/>
  <policy domain="coder" rights="none" pattern="{PS,PS2,PS3,EPS,PDF,XPS}"/>
  <policy domain="coder" rights="none" pattern="{MSL,MVG,MAGICK,TEXT,SHOW,WIN,PLT}"/>
  <policy domain="coder" rights="none" pattern="{URL,HTTP,HTTPS,FTP}"/>
  <policy domain="path"  rights="none" pattern="@*"/>
  <policy domain="resource" name="memory" value="256MiB"/>
  <policy domain="resource" name="map"    value="512MiB"/>
  <policy domain="resource" name="width"  value="16KP"/>
  <policy domain="resource" name="height" value="16KP"/>
  <policy domain="resource" name="area"   value="128MP"/>
  <policy domain="resource" name="disk"   value="1GiB"/>
  <policy domain="resource" name="time"   value="60"/>
  <policy domain="resource" name="thread" value="1"/>
</policymap>
```

`domain="path" pattern="@*"` blocks ImageMagick's indirect-read syntax, which is how a crafted filename turns into an arbitrary file read.

`thread value="1"` plus `MAGICK_THREAD_LIMIT=1` in the environment is a production correctness fix, not just a security one: ImageMagick's OpenMP pool spawns per process, so N FPM children each opening a thread pool will thrash a CPU-limited container. Consumers doing heavy batch work in `queue` can raise it.

**Trixie is ImageMagick 7, confirmed.** `install-php-extensions` branches on the Debian major version and pulls `libmagickwand-7.q16-*` / `libmagickcore-7.q16-*-extra` (plus `libheif-plugin-aomenc`) on 13+, versus the `6.q16` packages on bookworm. The policy therefore lands at `/etc/ImageMagick-7/policy.xml`. The build still writes to whichever directory exists, so a future suite bump doesn't silently drop the policy on the floor.

**Consequence for consumers:** LaraOCI images link imagick against **ImageMagick 7**, not 6. Anyone migrating from a bookworm-based image is changing major ImageMagick versions at the same time - a handful of Imagick API behaviours differ between IM6 and IM7. This belongs in the README's migration notes, not buried in a changelog.

**The image contains no ImageMagick CLI tools.** Only the libraries are installed, so `identify`, `convert`, and `magick` do not exist. Policy assertions must go through PHP (§10.1), not through `identify -list policy`.

**The `-extra` codec package is unavoidable** via this installer path. It brings DjVu, WMF, OpenEXR, and RAW decoders - more parser surface than a Laravel app typically needs. The delegate denial blunts the worst of it, and the weekly rebuild (§9.3) is the ongoing control.

**The size half of that argument does not survive measurement.** M1 built the image twice, identical but for the package, and the delta was **0.08 MB compressed**: `libmagickcore-7.q16-10-extra` is a 295 KB shim of coder modules. The decoders arrive as its dependencies and survive `--auto-remove` for the same reason the Ghostscript tree did, so reclaiming them means naming them - `libopenexr-3-1-30`, `libdjvulibre21`, `libdjvulibre-text`, `libwmflite-0.2-7`, **8.7 MB installed** between them. A wider sweep that also takes decoders owned by ImageMagick *core* (`libraw23t64`, `libheif1`, `libopenjp2-7`, the libheif plugins) reaches 13.5 MB installed, but those are not `-extra`'s to give back. The 70–100 MB imagick costs is ImageMagick proper. Hand-rolling the apt install to skip `-extra` is therefore **not** a size escape hatch; if it happens it is a parser-surface argument.

**Escape hatch if size becomes a complaint:** publish `-slim` variants without imagick rather than reversing the default. That reopens the matrix, so it happens on evidence, not speculation - and per the numbers above, `-slim` (LOCI-056) must be argued on CVE and parser surface, with those figures stated so nobody expects a size win.

### 3.3 Why FrankenPHP gets a second root (D16)

FrankenPHP embeds a Caddy web server, which reads as a direct violation of §14's "no opinionated infrastructure." The distinction that resolves it: LaraOCI would not be adding a web server *alongside* PHP - in FrankenPHP, the server **is** the SAPI, the same way `php-fpm` is a SAPI. Shipping `laraoci/fpm` without shipping Nginx is consistent; shipping `laraoci/frankenphp` is the same shape.

The genuine architectural cost is different: FrankenPHP is distributed as `dunglas/frankenphp`, not as a `php:` variant, and it embeds its own PHP build with its own extension set. It therefore **cannot descend from `laraoci/runtime`** without either compiling FrankenPHP from source (a large, ongoing maintenance commitment) or duplicating the extension layer.

This breaks §2.2 for exactly one image. The decision is to accept the second root and document it, rather than distort the rest of the design to preserve a clean graph. It is deferred to post-v1 and needs its own design note covering worker mode, the Octane driver, `clear_env` equivalence, and how the runtime contract of §6 is upheld on a base LaraOCI does not control.

---

## 4. Image Catalog

| Image       | Parent               | Purpose                                                         | Published  |
|-------------|----------------------|-----------------------------------------------------------------|------------|
| `runtime`   | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy | Yes        |
| `cli`       | `runtime`            | Artisan commands, one-off tasks, migrations                     | Yes        |
| `fpm`       | `runtime`            | PHP-FPM behind Nginx/Caddy/Traefik                              | Yes        |
| `builder`   | `runtime`            | Composer + Node + build toolchain for multi-stage builds        | Yes        |
| `queue`     | `cli`                | Laravel queue worker                                            | Yes        |
| `scheduler` | `cli`                | Laravel scheduler                                               | Yes        |

`runtime` uses the **`fpm`** upstream variant, which ships the CLI binary as well - see D18/§3.4 for why this is the only single-root arrangement that actually works.

### Post-v1 variants

FrankenPHP (first, per D16), then Octane/Swoole, RoadRunner, Horizon, Reverb, and development variants with Xdebug.

Each must justify itself against D4: if it is `cli` plus a `CMD`, it is a thin derivative, not an image.

---

## 5. Configuration File

`config/images.yml` is the single source of truth. CI reads it with `yq` and emits a JSON matrix.

```yaml
version: 1

defaults:
  registry: ghcr.io/laraoci
  user:
    name: laravel
    uid: 1000
    gid: 1000
  workdir: /var/www/html
  debian: trixie
  platforms:
    - linux/amd64
    - linux/arm64

php:
  "8.3":
    status: supported
  "8.4":
    status: supported
    default: true
  "8.5":
    status: supported

extensions:
  core:
    - bcmath
    - exif
    - gd
    - imagick
    - intl
    - opcache
    - pcntl
    - pdo_mysql
    - pdo_pgsql
    - redis
    - sockets
    - zip

size_budgets:          # compressed, MB - enforced by D17
  runtime: 260         # MEASURED in M1 - the 220 shown in the v2 draft was already too low
  cli: 260             # MEASURED and frozen in M2
  fpm: 260             # MEASURED and frozen in M2
  builder: 330         # MEASURED and frozen in M2 - the 500 placeholder was far too generous
  queue: 225           # placeholder - known wrong, see below
  scheduler: 225       # placeholder - known wrong, see below

images:
  runtime:
    dockerfile: images/runtime/Dockerfile
  cli:
    parent: runtime
  fpm:
    parent: runtime
    exposes: [9000]
  builder:
    parent: runtime
  queue:
    parent: cli
  scheduler:
    parent: cli
```

### Schema rules

- `php.<version>.status` ∈ `supported` | `deprecated`. Only `supported` is built; `deprecated` keeps existing tags but stops receiving rebuilds.
- Exactly one PHP version carries `default: true`. It backs `:latest`.
- `php.<version>.debian` overrides `defaults.debian` - the transition mechanism of §3.1, unset in normal operation.
- `images.<name>.parent` defines build order. CI topologically sorts; no hand-maintained ordering.
- `size_budgets` are frozen against measurement, one milestone at a time. CI fails on exceeding them. `runtime` was measured and frozen in M1 (§3.2, `docs/size-report-m1.md`); `cli`, `fpm` and `builder` were measured and frozen in M2 (`docs/size-report-m2.md`); `queue` and `scheduler` are still placeholders until M3, are known to be *below* `cli` which they descend from, and so fail the moment those images build - deliberately, as the reminder to measure.

  One formula produces every frozen number, so they stay comparable across milestones:

      ceil(max(8.3, 8.4, 8.5) × 1.10 / 5) × 5

  The 10% headroom absorbs Debian package drift between the weekly rebuilds (§9.3); rounding to 5 MB keeps the committed number readable. Size grows monotonically with the PHP minor on every image measured so far, so 8.5 sets each budget and a future 8.6 should be expected to raise it.

  **`cli` and `fpm` landing on `runtime`'s own 260 is the correct outcome, not a copy-paste error.** `cli` adds only `ENV` and `CMD` - zero bytes - and `fpm` adds `libfcgi-bin`, `libfcgi0t64` and one rendered pool file, together about 0.5 MB compressed. Both are far inside the rounding step, so all three round identically. The placeholders they replaced (225 and 235) were *below* the parent they descend from, which is impossible by construction - which is exactly why they were placeholders.

Matrix size: 3 PHP × 6 images × 2 arches = **36 build legs** per release. Development builds cut this to affected images on amd64 only.

---

## 6. Runtime Contract

The public API of the images. Changes here are breaking changes.

### 6.1 Filesystem and identity

| Property          | Value                                                    |
|-------------------|----------------------------------------------------------|
| User / group      | `laravel` (1000:1000)                                    |
| Working directory | `/var/www/html`                                          |
| App ownership     | `laravel:laravel`                                        |
| Writable paths    | `/var/www/html/storage`, `/var/www/html/bootstrap/cache` |
| Init              | `/usr/bin/tini -- <entrypoint>`                          |
| LaraOCI assets    | `/usr/local/share/laraoci/`                              |

All images run as `USER laravel`. No `sudo`, no setuid binaries beyond what Debian ships.

### 6.2 Signals and lifecycle

- `ENTRYPOINT` and `CMD` are **exec form** in every image.
- `pcntl` and `posix` are compiled in. Without them `queue:work` cannot trap `SIGTERM` and every deploy kills jobs mid-execution.
- `STOPSIGNAL SIGTERM`, stated explicitly.
- Documented requirement: the orchestrator's grace period must exceed the longest job timeout (`terminationGracePeriodSeconds`, `stop_grace_period`).

### 6.3 Logging

Everything to stdout/stderr. No log files in the container.

- `error_log = /proc/self/fd/2`, `log_errors = On`, `display_errors = Off`
- FPM: `error_log = /proc/self/fd/2`, `access.log = /proc/self/fd/2`, `daemonize = no`, `catch_workers_output = yes`, `decorate_workers_output = no`

`decorate_workers_output = no` matters: without it FPM prefixes every worker line and breaks JSON log parsing downstream.

**Most of this comes free from upstream.** The official `-fpm` image already writes `php-fpm.d/docker.conf` containing `clear_env = no`, both log redirections, `catch_workers_output`, `decorate_workers_output`, `log_limit`, and `listen = 9000`, plus `zz-docker.conf` with `daemonize = no`. LaraOCI's job is therefore **not to set these but to avoid clobbering them**, and to assert them in tests so an upstream change surfaces as a red build rather than a silent regression. LaraOCI's own pool file is additive (§7.3).

### 6.4 Environment

**`clear_env = no` in the FPM pool.** The single most common Laravel-in-Docker failure: with the FPM default, the application sees none of the container's environment and silently falls back to defaults.

| Variable                            | Default                                                   | Applies to   |
|-------------------------------------|-----------------------------------------------------------|--------------|
| `PHP_MEMORY_LIMIT`                  | `256M` (fpm) / `512M` (cli)                               | all          |
| `PHP_MAX_EXECUTION_TIME`            | `30` (fpm) / `0` (cli)                                    | all          |
| `PHP_UPLOAD_MAX_FILESIZE`           | `16M`                                                     | all          |
| `PHP_POST_MAX_SIZE`                 | `16M`                                                     | all          |
| `PHP_OPCACHE_ENABLE`                | `1`                                                       | all          |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS`   | `0`                                                       | all          |
| `PHP_OPCACHE_MEMORY_CONSUMPTION`    | `192`                                                     | all          |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `20000`                                                   | all          |
| `PHP_OPCACHE_PRELOAD`               | *(unset)*                                                 | all          |
| `LARAOCI_PRELOAD_ROOT`              | `/var/www/html`                                           | all          |
| `LARAOCI_PRELOAD_PATHS`             | `vendor/laravel/framework/src/Illuminate,vendor/composer` | all          |
| `LARAOCI_PRELOAD_IGNORE`            | see §7.7                                                  | all          |
| `MAGICK_THREAD_LIMIT`               | `1`                                                       | all          |
| `MAGICK_TMPDIR`                     | `/tmp`                                                    | all          |
| `LARAOCI_DEFAULT_BINARY`            | `php-fpm` (fpm) / `php` (cli, builder, queue, scheduler)  | all (D23)    |
| `PHP_FPM_PM`                        | `dynamic`                                                 | fpm          |
| `PHP_FPM_MAX_CHILDREN`              | `20`                                                      | fpm          |
| `PHP_FPM_START_SERVERS`             | `4`                                                       | fpm          |
| `PHP_FPM_MIN_SPARE_SERVERS`         | `2`                                                       | fpm          |
| `PHP_FPM_MAX_SPARE_SERVERS`         | `6`                                                       | fpm          |
| `PHP_FPM_MAX_REQUESTS`              | `500`                                                     | fpm          |
| `PHP_FPM_PROCESS_CONTROL_TIMEOUT`   | `10s`                                                     | fpm          |
| `COMPOSER_HOME`                     | `/home/laravel/.composer`                                 | builder      |
| `NPM_CONFIG_CACHE`                  | `/home/laravel/.npm`                                      | builder      |

`LARAOCI_DEFAULT_BINARY` is a **signal, not a knob** (D23): it tells the entrypoint which binary a dash-first argument means on this image, and overriding it at `docker run` time changes what `docker run … -v` starts. It is listed because `docker inspect` should answer the question without anyone reading a Dockerfile.

`PHP_FPM_PROCESS_CONTROL_TIMEOUT` is the one `PHP_FPM_*` variable that is **not** a pool directive - it renders into `[global]`, and it is what makes `STOPSIGNAL SIGQUIT` mean anything (§7.3).

Rendered by the entrypoint via `envsubst` against templates in `/usr/local/share/laraoci/templates/`. The generated file is `zz-laraoci.ini`, so any lexically later mount wins. The entrypoint **refuses to render a template whose variables are unset or empty**, so a missing value is a loud start-up failure rather than a blank directive that php-fpm silently accepts.

### 6.5 PHP configuration baseline

```ini
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /proc/self/fd/2
date.timezone = UTC
realpath_cache_size = 4096K
realpath_cache_ttl = 600

opcache.enable = 1
opcache.enable_cli = 1
opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
opcache.memory_consumption = 192
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.jit = disable
```

`opcache.enable_cli = 1` is deliberate: `queue` and `scheduler` are long-lived CLI processes. `validate_timestamps = 0` means **the container must be replaced to pick up code changes** - correct for immutable deploys, documented loudly for anyone bind-mounting source.

No `disable_functions`. Laravel and its ecosystem use `proc_open` and `exec` legitimately; blanket disabling produces confusing breakage rather than security.

---

## 7. Per-Image Specification

### 7.1 `runtime`

Installs: CA certificates, `tini`, the core extension set, the hardened ImageMagick policy, the `laravel` user, the ini baseline, the preload script, and the entrypoint.

Does **not** install: Composer, git, Node, build toolchains, **Ghostscript**, `procps`.

Removed before the layer commits: `docker-php-extension-installer`, `*-dev` packages, apt lists.

```dockerfile
ARG PHP_VERSION
ARG DEBIAN_RELEASE=trixie
FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}

ARG USER_UID=1000
ARG USER_GID=1000

COPY --from=mlocati/php-extension-installer:2 \
     /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
      bcmath exif gd imagick intl opcache pcntl \
      pdo_mysql pdo_pgsql redis sockets zip \
 && apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && apt-get purge -y --auto-remove ghostscript \
 && rm -rf /var/lib/apt/lists/* /usr/local/bin/install-php-extensions

# Policy lands in whichever ImageMagick config dir exists (6 vs 7)
COPY config/imagemagick/policy.xml /tmp/policy.xml
RUN set -eux; \
    for d in /etc/ImageMagick-7 /etc/ImageMagick-6; do \
      [ -d "$d" ] && install -m 0644 /tmp/policy.xml "$d/policy.xml"; \
    done; \
    rm /tmp/policy.xml

RUN groupadd -g ${USER_GID} laravel \
 && useradd -u ${USER_UID} -g laravel -m -s /bin/sh laravel \
 && mkdir -p /var/www/html \
 && chown laravel:laravel /var/www/html

COPY --chmod=0644 config/php/*.template  /usr/local/share/laraoci/templates/
COPY --chmod=0644 config/php/preload.php  /usr/local/share/laraoci/preload.php
COPY --chmod=0755 bin/entrypoint.sh       /usr/local/bin/laraoci-entrypoint

ENV MAGICK_THREAD_LIMIT=1 MAGICK_TMPDIR=/tmp

WORKDIR /var/www/html
USER laravel
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/laraoci-entrypoint"]
CMD ["php", "-v"]
```

*Illustrative - labels, digest pinning, and healthcheck omitted; see §11.*

**Risk retired.** The concern was that PECL imagick lags new PHP minors. `docker-php-extension-installer`'s support matrix lists `imagick` - along with every other extension in the §5 core set - as supported on **5.5 through 8.5** inclusive. D13 and D15 are compatible; the extension set stays uniform across all three versions rather than becoming per-version.

### 7.2 `cli`

`runtime` plus a default command, two per-SAPI `ENV` values, and the signal that says what a dash-first argument means. For `php artisan migrate`, `tinker`, ad-hoc tasks, and as parent of `queue`/`scheduler`.

```dockerfile
ENV LARAOCI_DEFAULT_BINARY=php
ENV PHP_MEMORY_LIMIT=512M \
    PHP_MAX_EXECUTION_TIME=0
CMD ["php", "artisan", "list"]
```

`LARAOCI_DEFAULT_BINARY` (D23) is the whole of the difference in behaviour, and it fixes two bugs with one value. Upstream's `docker-php-entrypoint` prepends `php-fpm` whenever the first argument starts with a dash - correct on `fpm`, wrong on every image that inherits the same script from the `-fpm` base (D18). So `docker run cli -r 'echo 1;'` would start an FPM master, **and** the SAPI gate of D22 would read that one-off command as an FPM process and enable a preload the process discards on exit. The LaraOCI entrypoint does the prepend itself, before handing off, so upstream's version sees an argv that no longer starts with a dash and can never fire. The default is `php-fpm`, so an image that does not set the variable behaves exactly as it did before.

The two `ENV`s are §6.4's cli column: a CLI process is not serving an HTTP request, so FPM's request ceiling is the wrong default. `artisan migrate` on a large table must not die at 30 seconds, and `tinker` should not die at 256 MB. `queue` and `scheduler` inherit both, and `builder` sets the same pair for the same reason - Composer's solver on a real Laravel tree does not fit in 256 MB.

No Composer (D6).

### 7.3 `fpm`

`runtime` plus a pool overlay and a command. **No SAPI installation** - `runtime` already carries `php-fpm` by way of D18.

The upstream image supplies `php-fpm.d/docker.conf` and `zz-docker.conf`, which between them already set `clear_env = no`, both log redirections, `catch_workers_output = yes`, `decorate_workers_output = no`, `listen = 9000`, and `daemonize = no`. LaraOCI adds only what is missing. The file is named `zz-laraoci.conf`, which sorts after `zz-docker.conf`, so LaraOCI wins where the two overlap and a consumer mount can still win over both.

FPM concatenates `php-fpm.d/*.conf` in glob order and section headers persist across file boundaries, so the LaraOCI file must declare its own `[www]` header rather than relying on the preceding file's.

```ini
[global]
process_control_timeout = ${PHP_FPM_PROCESS_CONTROL_TIMEOUT}

[www]
user = laravel
group = laravel

pm = ${PHP_FPM_PM}
pm.max_children = ${PHP_FPM_MAX_CHILDREN}
pm.start_servers = ${PHP_FPM_START_SERVERS}
pm.min_spare_servers = ${PHP_FPM_MIN_SPARE_SERVERS}
pm.max_spare_servers = ${PHP_FPM_MAX_SPARE_SERVERS}
pm.max_requests = ${PHP_FPM_MAX_REQUESTS}

ping.path = /fpm-ping
ping.response = pong
pm.status_path = /fpm-status

php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on
```

**Correction (M2).** Earlier drafts of this section also set `listen`, `clear_env`, `catch_workers_output`, `decorate_workers_output` and `access.log`. All five are upstream's already - `docker.conf` carries four of them and `zz-docker.conf` carries `daemonize` - and they are **removed** here rather than restated. Verified live on the built image. A second copy is a second thing to drift on a base bump, so they are asserted instead: statically via `php-fpm -tt` in `tests/structure/fpm.yaml`, and behaviourally for `clear_env` by the §10.3 smoke test (the one double-assertion D24 allows). `EXPOSE 9000` is likewise already set upstream and is asserted, not re-declared.

**`user`/`group` are inert on the default path, and are kept anyway.** The FPM master runs as `laravel`, and a non-root master cannot `setuid`, so these two directives do nothing - php-fpm says so at every start, twice, verified live:

```
NOTICE: [pool www] 'user' directive is ignored when FPM is not running as root
NOTICE: [pool www] 'group' directive is ignored when FPM is not running as root
```

That is **expected output, not a misconfiguration**, and it is named here so nobody "fixes" it later. The lines stay because `www.conf` sets `user = www-data` and sorts *before* this file: they are the only thing standing between `docker run --user 0` and workers running as `www-data` (33), which would break D8's shared-storage ownership contract exactly when someone reaches for `--user 0` to work around a permissions' problem. So this section's original framing - "set only the pieces that are actually missing" - is wrong about these two. They are not missing pieces; they are deliberate no-ops on the default path and a safety net off it.

**The `[global]` section is load-bearing, and so is the `[www]` header that follows it.** `process_control_timeout` is a global directive; php-fpm refuses to start if it appears under `[www]`. And because FPM section headers persist *across* file boundaries, opening `[global]` here means the pool directives below must re-declare `[www]` or they would land in `[global]`.

**`STOPSIGNAL SIGQUIT` is not sufficient on its own** - this was measured, and it contradicts what §6.2 and earlier drafts of this section imply. Against an in-flight request, with FPM's default `process_control_timeout = 0`, SIGQUIT takes the graceful *code path* (the master logs "Finishing" rather than "Terminating") and then exits without waiting for its busy children, truncating the response exactly as SIGTERM does. The timeout is what makes the signal mean anything:

| signal  | `process_control_timeout = 0`      | `= 10s`                           |
|---------|------------------------------------|-----------------------------------|
| SIGQUIT | exits 0.2s, response **truncated** | exits 4.9s, response **complete** |
| SIGTERM | exits 0.1s, response truncated     | exits 0.2s, response truncated    |

It is a ceiling, not a delay: an idle container still stops in ~0.2s. 10s matches Docker's default stop grace, past which `docker stop` sends SIGKILL regardless. Consumers with longer requests must raise **both** this and the orchestrator's grace period (`docker stop -t`, or `terminationGracePeriodSeconds`); raising one silently keeps the shorter.

**Healthcheck:** `cgi-fcgi -bind -connect 127.0.0.1:9000` against `/fpm-ping`, requiring `libfcgi-bin` in `fpm` only - measured at 133 KB installed (41 KB `libfcgi-bin` + 92 KB `libfcgi0t64`), against the ~200 KB estimated here originally. A container that cannot report its own health is worse than one 133 KB larger. `/fpm-ping` and `/fpm-status` are pool-internal paths answered by FPM itself: they never reach PHP, so an application route cannot shadow them and the check stays honest when the application is broken.

### 7.4 `builder`

`runtime` plus Composer, git, unzip, Node LTS, npm. **Not for production runtime** - stated in the description, the README, and `org.opencontainers.image.description`.

```dockerfile
FROM ghcr.io/laraoci/builder:8.4 AS build
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --prefer-dist --no-interaction
COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative \
 && npm ci && npm run build

FROM ghcr.io/laraoci/fpm:8.4
COPY --from=build --chown=laravel:laravel /var/www/html /var/www/html
```

`COMPOSER_HOME` (`/home/laravel/.composer`) and `NPM_CONFIG_CACHE` (`/home/laravel/.npm`) are part of the runtime contract so consumers can mount BuildKit caches:

```dockerfile
RUN --mount=type=cache,target=/home/laravel/.composer,uid=1000,gid=1000 \
    composer install --no-dev --prefer-dist --no-interaction
```

**The `USER` sequencing is load-bearing (D25).** Root is held for the apt/symlink/mkdir block only; the image returns to `USER laravel` *before* the contract `ENV`s and the `CMD`. Both cache directories are created explicitly and owned `1000:1000`, because a cache path that only root can write turns every consumer's cache mount into a silent no-op - or a build failure - and the `uid=1000` in the mount above would otherwise fight the directory's ownership.

**Composer's toolchain, not a general one.** `builder` carries `git` and `unzip` (Composer's VCS and archive paths), Composer itself and Node/npm - all four arriving as digest-pinned `COPY --from` rather than a third-party apt repository or a piped installer, so the whole toolchain is multi-arch by construction and Renovate updates a digest.

**Limitation: npm packages needing a native build will not compile.** `node-gyp` requires `python3`, which is **not** installed - only the C/C++ toolchain inherited from the upstream PHP image (`make`, `gcc`, `g++`) is present, and that is not enough on its own. Packages shipping prebuilt binaries are unaffected, which covers the ordinary Laravel front-end stack. A consumer needing `node-gyp` should `apt-get install -y python3` in their own build stage - one line, consciously theirs, and the same routing §14 gives Ghostscript.

**Not a production runtime.** It carries a package manager, a VCS client and a JavaScript runtime, none of which belong next to application code that serves requests. Stated in `org.opencontainers.image.description`, applied from `config/images.yml`, and pinned by `tests/structure/builder.yaml`.

**D3a - reversing the v1 draft's amd64-only builder.** The original rationale was that Node toolchain builds under QEMU emulation are punishingly slow. That rationale is obsolete: native ARM64 GitHub-hosted runners are available, so the ARM builder leg runs natively at roughly amd64 speed. Meanwhile, the consumer-side argument is strong - every developer on Apple Silicon running this multi-stage build locally would otherwise emulate the entire `composer install` and `npm ci`. Builder ships multi-arch.

### 7.5 `queue`

```dockerfile
FROM ghcr.io/laraoci/cli:${TAG}
CMD ["php", "artisan", "queue:work", \
     "--no-interaction", "--tries=3", "--max-time=3600", "--rest=0.1"]
```

`--max-time=3600` bounds worker lifetime so leaks and stale state never accumulate; the container restarts cleanly.

No `HEALTHCHECK`. A queue worker has no meaningful synchronous health signal, and a naive one is worse than none. Documented alternative: `queue:monitor` on a schedule, or Horizon.

Documented warning: **the orchestrator grace period must exceed `--timeout`.** Laravel's 60 s default job timeout against Docker's 10 s default grace kills in-flight jobs on every deploy.

### 7.6 `scheduler`

```dockerfile
FROM ghcr.io/laraoci/cli:${TAG}
CMD ["php", "artisan", "schedule:work", "--no-interaction"]
```

Documented constraint: **exactly one replica.** Two scheduler containers double-fire every task. HA requires `withoutOverlapping` and a shared cache lock - application configuration, not image configuration.

### 7.7 Preload (D14)

Ships at `/usr/local/share/laraoci/preload.php`, **inert unless** `PHP_OPCACHE_PRELOAD` names it.

```bash
PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
PHP_OPCACHE_MEMORY_CONSUMPTION=320
```

```php
<?php
declare(strict_types=1);

$root   = getenv('LARAOCI_PRELOAD_ROOT') ?: '/var/www/html';
$paths  = getenv('LARAOCI_PRELOAD_PATHS')
       ?: 'vendor/laravel/framework/src/Illuminate,vendor/composer';
$ignore = getenv('LARAOCI_PRELOAD_IGNORE')
       ?: '/tests/,/Tests/,/stubs/,/Stubs/,/Testing/,/migrations/,/resources/,/Console/';

$ignores  = array_filter(explode(',', $ignore));
$compiled = $skipped = 0;

// "Can't preload unlinked class" is a benign warning; keep startup logs clean.
set_error_handler(static fn () => true);

foreach (array_filter(explode(',', $paths)) as $relative) {
    $dir = rtrim($root, '/') . '/' . trim($relative, '/');
    if (! is_dir($dir)) {
        continue;
    }

    $files = new RegexIterator(
        new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
        ),
        '/\.php$/'
    );

    foreach ($files as $file) {
        $path = $file->getPathname();

        foreach ($ignores as $needle) {
            if (str_contains($path, $needle)) {
                $skipped++;
                continue 2;
            }
        }

        try {
            opcache_compile_file($path) ? $compiled++ : $skipped++;
        } catch (Throwable) {
            $skipped++;
        }
    }
}

restore_error_handler();

// NOT fwrite(STDERR, ...) - see the constraint below. error_log() is the only
// mechanism measured to survive preload AND reach stderr.
error_log(sprintf('laraoci: preloaded %d files, skipped %d', $compiled, $skipped));
```

Constraints documented alongside it:

- **Preload is FPM-only by default (D22).** Setting `PHP_OPCACHE_PRELOAD` is necessary but not sufficient: the entrypoint writes the `opcache.preload` directive into `zz-laraoci-preload.ini` only when the launched command is `php-fpm`. CLI opcache is per-process - the shared segment is created at startup and destroyed at exit - so on `cli` every `php artisan` call would pay the full preload compile cost and discard the result. Long-lived CLI workers that genuinely benefit, `queue` above all, opt in with **`LARAOCI_PRELOAD_FORCE=1`**. A stale directive from a previous start is cleared on the next one, so a container that stops qualifying does not keep preloading. `opcache.enable_cli` stays `1` regardless (§6.5) - that is what makes queue workers worth the opt-in.
- **Requires `vendor/` to exist at container start.** With an empty root the script no-ops and logs zero - silent, not fatal, by design.
- **Requires a container restart to change anything preloaded.** Consistent with `validate_timestamps = 0`.
- **Costs opcache memory.** Preloaded entries count against `opcache.memory_consumption`; the documented pairing raises it to 320 MB. `max_accelerated_files` must exceed the preloaded file count.
- **The startup line goes through `error_log()`, never `fwrite(STDERR, …)` (D32).** `STDIN`/`STDOUT`/`STDERR` are registered by the SAPI *after* opcache executes the preload script, so the constant does not exist yet - and an uncaught `Error` during preload **aborts startup**, so the v1 listing of this script did not merely log badly, it refused to start every container that enabled preload and the FPM master with it. `fopen('php://stderr')` fails the same way but **silently** (exit 255, no message), which is the trap for anyone "fixing" this. Measured on 8.3/8.4/8.5, CLI and a non-root FPM master. The cost is the `[date] ` prefix `error_log = /proc/self/fd/2` adds, so everything that reads this line matches it as a substring.
- **No `opcache.preload_user` needed.** That directive is only required when the FPM master runs as root; LaraOCI runs as `laravel` throughout. Verified from both sides on 8.3/8.4/8.5: the same image run as **root** dies with `"opcache.preload" requires "opcache.preload_user" when running under uid 0`, and at uid 1000 it preloads and reaches "ready to handle connections".
- Application code is deliberately *not* in the default path set. Preloading app classes is a real optimisation but is application-specific; consumers point `LARAOCI_PRELOAD_PATHS` at `app` themselves.
- **`vendor/symfony` is deliberately excluded from the default**, reversing the v1 draft. Illuminate's own preloading drags in the Symfony components it actually uses; compiling the full tree additionally loads Console, Mailer, and HttpKernel subtrees that most applications never touch, inflating preload memory for no hit-rate gain. It is also the largest source of benign "unlinked class" skips, which makes the startup line misleading. Documented as an opt-in append.
- **`/Console/` is in the default ignore set (D33), as the consequence of the exclusion above.** Without the Symfony tree, `Illuminate\Console\Command` cannot link its parent, and the ~78 artisan commands extending it fail behind it - so the default was compiling 130 classes that provably could not be preloaded, and saying so 176 times at every start. Measured on a Laravel 13 tree (2026-07-31): the entry removes 131 of those 176 warnings and 2.35 MB of preload memory, and costs 80 genuinely-preloaded classes that are on no hot path - `fpm` never touches console code in a request, and `queue` loads it once at worker start and then runs for up to `--max-time=3600`. Adding `vendor/symfony` back instead was measured and rejected: 153 warnings for +12.5 MB. Consumers with artisan-heavy workloads restate the list without the entry.
- **About 45 "unlinked class" warnings remain and are expected output.** Their parents live in `Symfony\…`, `Psr\…`, `Monolog\…` and `GuzzleHttp\…`, all outside the path set by design. Reaching zero would mean preloading those trees at a memory cost the default declines. The documentation says so, so that an operator reads them as normal rather than as a fault.
- Tuning is measurable: `opcache_get_status()['preload_statistics']` reports the memory consumed and the class/function counts. The docs show this rather than asserting a number.

---

## 8. Tagging Policy

Each image type is its own GHCR package: `ghcr.io/laraoci/{runtime,cli,fpm,builder,queue,scheduler}`.

| Tag form      | Example                   | Mutability    | Use                      |
|---------------|---------------------------|---------------|--------------------------|
| PHP minor     | `:8.4`                    | Rolling       | Dev, non-critical        |
| PHP + Debian  | `:8.4-trixie`             | Rolling       | Explicit OS pin          |
| Dated         | `:8.4-trixie-20260724`    | **Immutable** | Production               |
| Patch + dated | `:8.4.10-trixie-20260724` | **Immutable** | Strict pinning           |
| Digest        | `@sha256:…`               | **Immutable** | Supply-chain-strict      |
| `:latest`     |                           | Rolling       | Default PHP version only |

- Dated tags are **never** overwritten; a same-day rebuild appends `-2`.
- Rolling tags are repointed by scheduled rebuilds (§9.3), in a job gated on the whole matrix. A partially-failed matrix must never leave `:8.4` half-updated.
- README recommends dated tags or digests for production, with Renovate and Dependabot config examples.

---

## 9. Build Pipeline

### 9.1 Development builds (`pull_request`)

Affected images only - changed paths mapped through the `parent` graph, so a `runtime` change rebuilds everything downstream and a `queue` change rebuilds only `queue`. amd64 only, built and loaded but not pushed, full test suite (§10), advisory-only vulnerability scan.

**Correction (M2, D27).** This path carries **no GHA layer cache**. A child image's `FROM ghcr.io/laraoci/<parent>` resolves to nothing until M4 publishes, so each leg first builds its own ancestor chain into the local daemon - which requires buildx's `docker` driver, whose builder *is* the daemon. The `docker-container` driver that supports `cache-to`/`cache-from: type=gha` cannot see a loaded image at all, so the two are mutually exclusive on this path. The cache was inert here regardless: PR legs are forbidden from writing the shared cache (so nothing seeds it) and nothing else writes it. The push path of §9.2 keeps the container driver and the cache. `runtime` is rebuilt once per child leg - 9 extra builds per PR at M2 - all in parallel, so wall-clock is unchanged.

### 9.2 Release builds (tag push or manual dispatch)

Full 36-leg matrix. Native amd64 and arm64 runners, multi-platform manifest lists, SPDX SBOM, SLSA provenance (`mode=max`), Cosign keyless signing via GitHub OIDC. Vulnerability scan is a **hard gate** on fixable `CRITICAL` and `HIGH`. Size budgets (D17) enforced. Rolling tags repointed only after every leg succeeds.

### 9.3 Scheduled rebuilds (weekly)

This is what keeps "secure" true. Upstream PHP images and Debian packages receive fixes continuously; an image built once accumulates CVEs no matter how careful the original build was.

Unconditional weekly rebuild of all `supported` versions - cheap, and avoids missing package-level updates that don't move the upstream digest. Produces a new dated tag and repoints rolling tags. On scan failure the run fails loudly and opens an issue rather than publishing.

Because imagick is now in the base layer (D13), the scheduled rebuild is not optional hygiene - it is the primary control on the largest CVE surface in the image.

**It does not work with the release path's cache policy, and this is load-bearing (D41).** "Unconditional" above has to mean the *layers* too. `build.yml` restores with `cache-from: type=gha`, and a layer's cache key is its `RUN` command plus its parent - the parent being pinned by `BASE_DIGEST`, which moves only when upstream rebuilds. In the case this section is written for, where Debian ships a fix and the upstream digest does **not** move, every input to that key is unchanged: the layer is restored, `apt-get update` never runs, and the rebuild produces a byte-identical image and reports success. The scan then passes on the same packages that failed last week, or fails identically forever.

Measured 2026-08-11: a freshly built image carried `linux-libc-dev` 6.12.100-1 while 6.12.101-1 was already apt's candidate in `trixie-security` (D40). M5 must therefore give the scheduled path its own cache policy - a `no-cache-filters` on the extension stage, a date-valued build arg, or an explicit upgrade step - and whichever it picks, the acceptance test is that a rebuild with no upstream digest change still produces a different image when Debian has published one.

---

## 10. Testing Strategy

### 10.1 Structure tests

`container-structure-test` per image, asserting §6:

- Runs as UID 1000
- `pcntl`, `posix`, `opcache`, `imagick` loaded
- `opcache.validate_timestamps = 0`, `expose_php = Off`
- **ImageMagick major version is 7** - asserted via `Imagick::getVersion()`
- **Policy is live**, asserted *through PHP* rather than through `identify -list policy`: the CLI tools are not installed (§3.2), so the test opens a `PDF:` pseudo-image and an `@`-prefixed indirect read and requires both to throw `ImagickException`
- **Ghostscript absent** - `command -v gs` fails
- Composer absent from `cli`/`fpm`/`queue`/`scheduler`, present in `builder`
- `clear_env = no` in the rendered FPM pool
- `tini` is PID 1
- `/var/www/html` owned by `laravel`
- **Compressed size within the `size_budgets` value** (D17)

### 10.2 Functional smoke test

Minimal Laravel skeleton at `tests/fixtures/app`:

1. `builder` -> `composer install`, `npm ci && npm run build`
2. `cli` -> `artisan migrate` on SQLite, `artisan about`
3. `fpm` + throwaway Nginx -> HTTP 200 on `/`, `/fpm-ping` returns `pong`
4. `queue` -> dispatch a job, assert processing, then `SIGTERM` mid-job and assert **graceful completion, not truncation** (the pcntl regression test)
5. `scheduler` -> run 70 s, assert exactly one execution of a per-minute task
6. **imagick** -> resize a JPEG through the `Imagick` class, then assert a crafted `PDF:` and an `@file` read both **fail** under policy
7. **preload** -> boot `fpm` with `PHP_OPCACHE_PRELOAD` set, assert non-zero preloaded count in stderr and HTTP 200 still served; boot with an empty `vendor/` and assert the container still starts

### 10.3 Environment passthrough test

Set an arbitrary env var on the `fpm` container, hit a route echoing `env()`, assert visibility. This is the `clear_env` regression test, and it gets its own named test because the failure mode is silent.

---

## 11. Supply Chain & Metadata

Every published image carries OCI labels (`source`, `revision`, `created`, `version`, `licenses`, `description`, `documentation`, `base.name`, `base.digest`), an SPDX SBOM attestation, SLSA provenance, a Cosign keyless signature, and a scan report uploaded to GitHub code scanning.

`cosign verify` instructions with the expected identity and issuer belong in the README, not only in CI. An unverifiable signature is decorative.

---

## 12. Repository Layout

```
.
├── config/
│   ├── images.yml
│   ├── imagemagick/policy.xml
│   └── php/
│       ├── zz-laraoci.ini.template
│       ├── zz-laraoci-fpm.conf.template
│       └── preload.php
├── images/
│   ├── runtime/Dockerfile
│   ├── cli/Dockerfile
│   ├── fpm/Dockerfile
│   ├── builder/Dockerfile
│   ├── queue/Dockerfile
│   └── scheduler/Dockerfile
├── bin/
│   ├── matrix.sh          # images.yml -> GHA JSON matrix
│   ├── affected.sh        # changed paths -> affected images
│   ├── build-chain.sh     # an image plus every ancestor, locally (D27)
│   ├── size-check.sh      # D17 budget enforcement
│   ├── structure-test.sh  # container-structure-test driver
│   ├── fetch-tools.sh     # checksum-pinned CI tooling
│   └── entrypoint.sh
├── tests/
│   ├── unit/*.bats        # bats: the scripts above
│   ├── structure/*.yaml   # per-image, plus _common.yaml for the shared contract
│   ├── fixtures/app/      # the minimal Laravel app the smoke suite drives
│   └── smoke/             # run.sh + compose.yml + nginx.conf + *.bats
├── docs/
└── .github/workflows/{build,pr,lint,smoke,release,scheduled}.yml
```

---

## 13. Support Policy

- A PHP version is `supported` while it receives upstream **security** support, then `deprecated`.
- `deprecated` versions keep their dated tags forever but stop receiving scheduled rebuilds. The rolling tag freezes and the README states the freeze date.
- Debian follows §3.1: one release for the whole matrix, migrated deliberately.
- LaraOCI's SemVer applies to the **runtime contract** (§6), not the PHP inside. Changing the UID, workdir, entrypoint behaviour, or a documented env default is a major bump. Adding or removing an extension is a minor bump and a release-note callout.

---

## 14. Non-Goals

LaraOCI is not a replacement for Docker Compose or Kubernetes, a deployment platform, a source of opinionated infrastructure (no Nginx, no databases, no Redis server, no Supervisor), or a kitchen-sink extension bundle.

Explicitly out of scope: web server configuration, TLS termination, secrets management, database provisioning, process supervision beyond one process per container, and - per D13 - **PDF and PostScript rasterisation**, which requires Ghostscript and is left to consumers who consciously want it.

Two deliberate exceptions, both argued rather than assumed: the `builder` image (§7.4), because the alternative is Composer in production images; and FrankenPHP post-v1 (§3.3), because there the server is the SAPI.

---

## 15. Roadmap

| Milestone                       | Content                                                                                                                                                                                                                                                                  | Exit criteria                                                                                                      |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| **M0 - Foundations**            | Repo scaffold, `config/images.yml`, matrix + affected + size-check scripts, PR workflow skeleton. Upstream trixie coverage already confirmed.                                                                                                                            | Matrix generation tested; empty build passes CI                                                                    |
| **M1 - Runtime**                | `runtime` image, extension set, **imagick + hardened policy**, ini baseline, entrypoint templating, user/UID, tini. **Measure real sizes and freeze budgets** - the §5 numbers are placeholders. Confirm the Ghostscript purge survives the installer's package marking. | Structure tests green on `runtime` for all three PHP versions, including policy and Ghostscript-absence assertions |
| **M2 - First images**           | `cli`, `fpm`, `builder`                                                                                                                                                                                                                                                  | Smoke tests 1–3 and 6 green; env passthrough green                                                                 |
| **M3 - Workers & preload**      | `queue`, `scheduler`, preload script and docs                                                                                                                                                                                                                            | Smoke tests 4, 5, 7 green, including SIGTERM graceful shutdown                                                     |
| **M4 - Release pipeline**       | Multi-arch, manifests, SBOM, provenance, Cosign, scan gate, size gate, tagging policy                                                                                                                                                                                    | First signed multi-arch release on GHCR, verified with `cosign verify`                                             |
| **M5 - Maintenance**            | Scheduled rebuild workflow, deprecation tooling, docs site, Renovate examples                                                                                                                                                                                            | One full scheduled cycle completed, rolling tags repointed                                                         |
| **M6 - FrankenPHP** *(post-v1)* | Design note first (§3.3), then implementation                                                                                                                                                                                                                            | Runtime contract §6 demonstrably upheld on the second root                                                         |

---

## 16. Resolved Decisions

| v1 question           | Resolution                                                    |
|-----------------------|---------------------------------------------------------------|
| PHP version floor     | 8.3, 8.4, 8.5 - all `supported`, no preview tier (D15)        |
| Shared layer naming   | `runtime` (D2)                                                |
| imagick               | Included, with hardened policy and no Ghostscript (D13)       |
| ARM builder           | Multi-arch - earlier amd64-only recommendation reversed (D3a) |
| Preload               | Opt-in script shipped at a fixed path (D14)                   |
| First post-v1 variant | FrankenPHP, with an accepted second root (D16)                |

## 17. Remaining Open Questions

Questions 1–3 of the v2 draft are closed against primary sources and folded into §3.1, §3.2, and §7.1. Questions 1 and 3 of the v3 list - the `runtime` size budget and the `libmagickcore-*-extra` scope - are closed against **M1 measurement** and folded into §3.2 and §5; the numbers and method live in `docs/size-report-m1.md`. What is left is genuinely unresolvable from a desk.

1. **Ghostscript purge durability.** The purge depends on `install-php-extensions` continuing to install Ghostscript as a normal package rather than pinning or holding it. M1 made this sharper, not softer: because the tree must be named explicitly (§3.2), a rename such as `libgs10` -> `libgs11` breaks the build rather than silently leaving the interpreter behind - loud, but on an unrelated PR. The structure test is the backstop. Still worth an upstream issue asking whether Ghostscript can be made opt-out.
2. **PHP 8.6.** An alpha is already built upstream with full trixie coverage. Confirm the intent to add it at GA as a fourth `supported` version - which takes the release matrix from 36 legs to 48 and makes the affected-images filter (§9.1) load-bearing rather than a nicety.
3. ~~**Budgets for the other five images.**~~ **CLOSED by M2 and M3.** All six are now measured and frozen in `config/images.yml`, and no placeholder survives. `cli`, `fpm` and `builder` were measured at M2 (`docs/size-report-m2.md`); `queue` and `scheduler` at M3 (`docs/size-report-m3.md`), where both landed on `runtime`'s own 260 because a `CMD` and an `ENV` create no filesystem layer. The v2-draft placeholders sat *below* the parent each image descends from, which is impossible by construction - and that impossibility was the point: each reported `OVER` the moment its image was first built.
