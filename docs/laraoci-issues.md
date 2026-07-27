# LaraOCI - GitHub Issue Set

56 issues across seven milestones, derived from `laraoci-spec.md`.
Seeded by `bin/seed-issues.sh`, which is the source of truth for issue bodies - this file is the map.

---

## Usage

```bash
gh auth status                                  # must be authenticated
./bin/seed-issues.sh --dry-run                  # inspect the plan
./bin/seed-issues.sh                            # seed everything
./bin/seed-issues.sh --milestone M1             # seed one milestone
REPO=laraoci/laraoci ./bin/seed-issues.sh       # explicit repo
```

**Idempotency.** Every body carries a trailing `<!-- LOCI-NNN -->` marker. The script caches the full issue list once and matches on that marker locally, so re-runs converge rather than duplicating and there is no dependency on GitHub's search index being current. Labels and milestones are upserted the same way.

**Dependency resolution.** Bodies are written with `{{LOCI-NNN}}` placeholders and resolved to `#N` in a second pass, once every issue exists. When seeding a single milestone, references to issues outside it degrade to a backticked marker rather than a broken link.

Requires `gh` and `jq`.

---

## Milestones

|        | Milestone           | Issues   | Theme                                                         |
|--------|---------------------|----------|---------------------------------------------------------------|
| **M0** | Foundations         | 10       | Scaffold, `config/images.yml`, matrix generation, PR pipeline |
| **M1** | Runtime             | 11       | The shared base layer and its contract                        |
| **M2** | CLI, FPM, Builder   | 10       | First consumable images                                       |
| **M3** | Workers and preload | 8        | Queue, scheduler, opcache preload                             |
| **M4** | Release pipeline    | 9        | Multi-arch, attestations, signing, tagging                    |
| **M5** | Maintenance         | 5        | Scheduled rebuilds, deprecation, docs                         |
| **M6** | Post-v1             | 3        | FrankenPHP, PHP 8.6, slim variant                             |

---

## Issues

### M0 - Foundations

| Marker   | Title                                                | Depends on    |
|----------|------------------------------------------------------|---------------|
| LOCI-001 | Repository scaffold                                  | -             |
| LOCI-002 | Community health files and issue forms               | -             |
| LOCI-003 | `config/images.yml` - schema and initial content     | -             |
| LOCI-004 | `bin/matrix.sh` - build matrix generation            | 003           |
| LOCI-005 | `bin/affected.sh` - changed paths to affected images | 003           |
| LOCI-006 | `bin/size-check.sh` - image size budget enforcement  | 003           |
| LOCI-007 | Reusable build workflow                              | -             |
| LOCI-008 | PR workflow                                          | 004, 005, 007 |
| LOCI-009 | Shell lint and script test harness                   | -             |
| LOCI-010 | Repository settings and branch protection            | -             |

### M1 - Runtime

| Marker   | Title                                                | Depends on         |
|----------|------------------------------------------------------|--------------------|
| LOCI-011 | runtime: Dockerfile skeleton and upstream pin        | 003, 007           |
| LOCI-012 | runtime: non-root user and filesystem layout         | 011                |
| LOCI-013 | runtime: core PHP extension installation             | 011                |
| LOCI-014 | runtime: purge Ghostscript and guarantee its absence | 013                |
| LOCI-015 | runtime: hardened ImageMagick policy                 | 013                |
| LOCI-016 | runtime: php.ini baseline template                   | 011                |
| LOCI-017 | runtime: entrypoint and envsubst config rendering    | 016                |
| LOCI-018 | runtime: tini init and exec-form entrypoint          | 017                |
| LOCI-019 | runtime: OCI image labels                            | 011, 007           |
| LOCI-020 | Structure test harness                               | 008                |
| LOCI-021 | runtime: structure tests and size budget freeze      | 014, 015, 018, 020 |

### M2 - CLI, FPM, Builder

| Marker   | Title                                                   | Depends on         |
|----------|---------------------------------------------------------|--------------------|
| LOCI-022 | cli image                                               | 021                |
| LOCI-023 | fpm: SAPI installation                                  | 021                |
| LOCI-024 | fpm: pool configuration template                        | 023, 017           |
| LOCI-025 | fpm: healthcheck                                        | 024                |
| LOCI-026 | builder image                                           | 021                |
| LOCI-027 | Test fixture: minimal Laravel application               | -                  |
| LOCI-028 | Smoke test harness                                      | 027, 008           |
| LOCI-029 | Smoke: builder to cli to fpm request path               | 028, 022, 025, 026 |
| LOCI-030 | Smoke: environment passthrough (`clear_env` regression) | 029, 024           |
| LOCI-031 | Smoke: imagick operation and policy denial              | 029, 015           |

### M3 - Workers and preload

| Marker   | Title                                              | Depends on  |
|----------|----------------------------------------------------|-------------|
| LOCI-032 | queue image                                        | 022         |
| LOCI-033 | scheduler image                                    | 022         |
| LOCI-034 | Preload script                                     | 021         |
| LOCI-035 | Preload environment plumbing and documentation     | 034         |
| LOCI-036 | Smoke: queue graceful shutdown under SIGTERM       | 032, 028    |
| LOCI-037 | Smoke: scheduler single-fire                       | 033, 028    |
| LOCI-038 | Smoke: preload enabled and empty-vendor safety     | 034, 029    |
| LOCI-039 | Operational docs: grace periods, replicas, opcache | 036, 037    |

### M4 - Release pipeline

| Marker   | Title                                            | Depends on              |
|----------|--------------------------------------------------|-------------------------|
| LOCI-040 | Multi-arch builds on native runners              | 007, 026                |
| LOCI-041 | Multi-platform manifest publication              | 040                     |
| LOCI-042 | SBOM and build provenance attestations           | 041                     |
| LOCI-043 | Cosign keyless signing                           | 041                     |
| LOCI-044 | Vulnerability scan gate                          | 040                     |
| LOCI-045 | Tagging policy implementation                    | 041                     |
| LOCI-046 | Rolling tag repoint gated on full matrix         | 045                     |
| LOCI-047 | Release workflow and release notes               | 042, 043, 044, 046, 006 |
| LOCI-048 | GHCR package configuration and verification docs | 047                     |

### M5 - Maintenance

| Marker   | Title                                     | Depends on   |
|----------|-------------------------------------------|--------------|
| LOCI-049 | Scheduled weekly rebuild workflow         | 047          |
| LOCI-050 | PHP version deprecation tooling           | 049, 003     |
| LOCI-051 | Documentation site                        | 039, 048     |
| LOCI-052 | Consumer Renovate and Dependabot examples | 045          |
| LOCI-053 | README: positioning and migration notes   | 051          |

### M6 - Post-v1

| Marker   | Title                               | Depends on |
|----------|-------------------------------------|------------|
| LOCI-054 | Design note: FrankenPHP second root | -          |
| LOCI-055 | PHP 8.6 readiness                   | 050        |
| LOCI-056 | Evaluate `-slim` variant            | 021        |

---

## Critical path

```
003 -> 004/005 -> 008 -> 020
                 ↓
011 -> 013 -> 014/015 -> 021 -> 022 -> 032/033 -> 036/037
                       ↓      ↓
                      026    023 -> 024 -> 025 -> 029 -> 030/031
                              ↓
                             040 -> 041 -> 042/043/045 -> 046 -> 047 -> 049
```

**LOCI-021 is the chokepoint.** Every image in M2 and M3 depends on it, and it carries the size-budget measurement that closes two open questions. Nothing downstream should start before it is green on all three PHP versions.

---

## Issues carrying decisions rather than just work

A handful encode reasoning that will be lost if they are treated as checklists:

- **LOCI-014** - Ghostscript is installed *by the extension installer*, unconditionally, and must be actively purged. The absence of `|| true` is the point.
- **LOCI-021** - asserts the ImageMagick policy *through PHP*, because the image ships no ImageMagick CLI tools. `identify -list policy` is unavailable.
- **LOCI-024** - `clear_env = no`. The most consequential single line in the repository.
- **LOCI-030** and **LOCI-036** - named separately from the smoke suite because both failure modes are silent or subtle: reading defaults instead of env, and truncating jobs instead of finishing them.
- **LOCI-046** - the repoint gate. A half-updated rolling tag is worse than a failed release.
- **LOCI-054** - a design note that must merge *before* any FrankenPHP implementation, because it may conclude the carve-out does not hold.
- **LOCI-056** - explicitly evidence-gated. Do not pre-emptively engineer a slim variant.

---

## Labels

`type:infra` · `type:image` · `type:ci` · `type:test` · `type:docs` · `type:security`
`area:runtime` · `area:cli` · `area:fpm` · `area:builder` · `area:queue` · `area:scheduler` · `area:pipeline`

Created and reconciled by the seed script.
