# Security Policy

## Supported versions

LaraOCI publishes images for every PHP version marked `supported` in
`config/images.yml` (currently 8.3, 8.4, 8.5). A version receives security
updates while its upstream security window is open; when it closes, the version
moves to `deprecated` - existing dated tags remain but stop receiving rebuilds.

## The security guarantee is the weekly rebuild

Images accumulate CVEs after they are built, no matter how careful the original
build was. LaraOCI's primary control is an **unconditional weekly rebuild** of
all `supported` versions (see LOCI-049 / spec §9.3), which pulls current PHP and
Debian package fixes and republishes dated tags. Because ImageMagick lives in
the base layer (D13), this rebuild is not optional hygiene - it is the main
control on the largest CVE surface in the image.

## CVE triage posture

- Release builds hard-gate on fixable `CRITICAL` and `HIGH` vulnerabilities.
- PR builds scan advisory-only.
- On a scan failure, the scheduled run fails loudly and opens an issue rather
  than publishing.

## Reporting a vulnerability

Report privately via GitHub Security Advisories on this repository. Please do
not open a public issue for an unpatched vulnerability.
