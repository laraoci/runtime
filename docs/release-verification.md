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
| `Assert the image metadata (§11, §6.2)`               | **Required.** Re-assert the OCI label set and `STOPSIGNAL` against the pushed digest: `docker buildx imagetools inspect --raw` for the labels, and a pull-then-`docker image inspect` for the stop signal (the manifest carries the config blob, so the inspect can read `.Config.StopSignal` per platform without running anything). `STOPSIGNAL` is the load-bearing half - `container-structure-test` has no field for it, so this workflow is the only place `images/fpm`'s `SIGQUIT` restoration is asserted, and without it every deploy truncates an in-flight response. |
| `Structure tests (§10.1)`                             | **Required.** Pull the pushed digest for the native platform and run `bin/structure-test.sh` against it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `Size report (D17, advisory on PRs)`                  | **Required, and enforcing rather than advisory** (spec §9.2, D17): drop `--report`, so an overrun exits 1 on the release path. Measure the pushed digest per platform.                                                                                                                                                                                                                                                                                                                                                                                                          |

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
