# What the release path must verify

M4 acceptance criteria. Nothing is published yet (D27), so nothing here is a live
defect - this exists so that none of it becomes one silently the day `push: true`
is first used. Recorded from the 2026-07-31 code review, findings 7 and 12.

## The problem this records

`.github/workflows/build.yml` runs every verification step it has on the **load**
path - `docker buildx build --load` into the runner's daemon, which needs a
single platform - and gates all of them on `!inputs.push`. The push path builds
multi-platform and pushes straight to the registry, where there is no local image
to inspect. So today:

**The artifact that gets published is the one artifact never verified.**

`build.yml`'s comment at 283-290 already says that about the structure tests. It
is equally true of three more steps, and one of them is the only place its
assertion exists at all.

## The five steps gated on `!inputs.push`

| Step (verbatim, as named in build.yml)                | What the push path must do instead                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Build the ancestor chain (🧭 5)`                     | Nothing. The chain exists so a local parent can be resolved by tag from the runner's daemon; on the push path the parent is pulled from the registry, which is the real thing. **No push-path equivalent needed.**                                                                                                                                                                                                                                                                                                                                                              |
| `Reject a multi-platform build that cannot be loaded` | Nothing. It is a guard *on the load path*, asserting that a `--load` build was given exactly one platform. Meaningless where nothing is loaded. **No push-path equivalent needed.**                                                                                                                                                                                                                                                                                                                                                                                             |
| `Assert the image metadata (§11, §6.2)`               | **Required.** `docker buildx imagetools inspect "$REF@$DIGEST" --format '{{ json .Image }}'`, piped to `bin/assert-metadata.sh --source registry`. Asserts the nine `org.opencontainers.image.*` labels are present and non-empty, and that `.config.StopSignal` equals `config/images.yml`'s `stopsignal` (absent means `SIGTERM`). **Nothing is pulled** - see the correction below. `STOPSIGNAL` is the load-bearing half - `container-structure-test` has no field for it, so this workflow is the only place `images/fpm`'s `SIGQUIT` restoration is asserted, and without it every deploy truncates an in-flight response. Implemented as `Assert the image metadata against the pushed digest (§11, §6.2)`. |
| `Structure tests (§10.1)`                             | **Required.** `docker pull "$REF@$DIGEST"`, then `bin/structure-test.sh --image "$IMAGE" --ref "$REF@$DIGEST"` - the full `tests/structure/<image>.yaml` + `_common.yaml` suite. The pull is native because the leg runs on the runner matching the platform it built (D3a), so **arm64 gets a real structure-test run** rather than a skipped one. Implemented as `Pull the pushed digest` and `Structure tests against the pushed digest (§10.1)`.                                                                                                                              |
| `Size report (D17, advisory on PRs)`                  | **Required, and enforcing rather than advisory** (spec §9.2, D17): `bin/size-check.sh --image "$IMAGE" --ref "$REF@$DIGEST"` with **no `--report`**, so an overrun exits 1. Measures the digest pulled by the row above, with the instrument that froze the budgets - `docker save \| gzip` - because enforcing a budget set by one instrument with a measurement from another turns a clean build into a spurious release block. Implemented as `Size budget against the pushed digest (D17, enforcing)`.                                                                        |

## Platform coverage (finding 12)

PRs build `linux/amd64` only (`pr.yml:63`), while `config/images.yml` declares
both `linux/amd64` and `linux/arm64`. `images/builder/Dockerfile:10` claims
multi-arch by construction and proves it with per-tool `--version` assertions -
but those only ever run on the architecture that was built.

The concrete risk is `builder`'s two `COPY --from=node:…@sha256:…` lines: a digest
that resolves to a manifest list today could be replaced by a single-arch one, and
`/usr/local/bin/node` would then be an amd64 ELF on the arm64 leg. Nothing would
notice until the release path first builds arm64 - and those digests are updated
by a bot, on a PR that cannot exercise the affected architecture.

**M4 requirement:** the release matrix builds both platforms, and at least
`builder` gets an arm64 leg whose tool assertions actually run there. Deliberately
not done earlier: on PRs it would mean either QEMU (a full arm64 PHP-extension
build per PR) or an arm64 runner, and runner selection is a `bin/matrix.sh` field
that does not exist yet. Both are the multi-platform release path itself.

## Enforcement

`tests/unit/workflows.bats` fails if `build.yml` gains a step gated on
`!inputs.push` that is not named in the table above. Adding a gate means adding a
row, with either a push-path equivalent or the reason there is none.

## The push-path steps, by name

`tests/unit/workflows.bats` reads the block below and requires each name to
exist in `.github/workflows/build.yml` as a step gated **on** `inputs.push`.
That is the reverse of the enforcement above, and it is the half that catches a
doc promising a verification the workflow never gained.

Change a step's name here and in the workflow together, or the suite goes red.

```text
Assert the image metadata against the pushed digest (§11, §6.2)
Pull the pushed digest
Structure tests against the pushed digest (§10.1)
Size budget against the pushed digest (D17, enforcing)
```

### Correction to the mechanism above

As first recorded on 2026-07-31, the metadata row above required "a
pull-then-`docker image inspect`" for the stop signal. It does not need one, and
the row has been corrected to the mechanism that shipped.
`docker buildx imagetools inspect --format '{{ json .Image }}'`
renders the OCI image config from the registry - including `config.StopSignal`
and `config.Labels` - and returns a **map keyed by platform** for a manifest
list. So the assertion that exists nowhere else is made against the published
bytes, for every architecture, with nothing pulled. `bin/assert-metadata.sh`
implements both that and the daemon form, so the two paths cannot drift.

The pull remains, for the structure tests and the size measurement, which do
need a local image. It is one pull per leg, of the platform that leg built, on
that platform's native runner.
