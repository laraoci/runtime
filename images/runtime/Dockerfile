# LaraOCI runtime - the shared base layer for every LaraOCI image (spec §7.1, D2).
#
# Derives from the -fpm upstream variant (D18 / §3.4): it ships
# /usr/local/bin/php as well as /usr/local/sbin/php-fpm, which is the only
# arrangement that makes the single-rooted image graph implementable. A -cli
# base cannot gain FPM without recompiling PHP.
#
# OCI labels are NOT set here. They are applied by .github/workflows/build.yml
# (LOCI-019) so that source, revision, created, and the resolved base digest
# come from the build context rather than from a hand-edited file per image.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}
# Identity is passed in from config/images.yml (D8 / §6.1). A UID that silently
# differs between images is the failure D8 exists to prevent, so these have no
# second source of truth: the workflow reads images.yml and passes them here.
ARG USER_NAME=laravel
ARG USER_UID=1000
ARG USER_GID=1000

COPY --from=mlocati/php-extension-installer:2@sha256:b6d3fa381b9ba5cf051117c1c601d6a523b590e534bf3d56eb4fbe352949c138 \
     /usr/bin/install-php-extensions /usr/local/bin/

# ---------------------------------------------------------------------------
# RUN 1 - BOUNDARY: this is the ONE instruction allowed to touch apt or the
# extension installer, and it is deliberately not split.
# install-php-extensions installs `ghostscript` unconditionally on Debian and
# marks it manually installed (§3.2). Docker layers are additive: purging it in
# a LATER RUN removes it from the final filesystem but leaves its bytes in this
# layer's tarball, where they still count toward image size and remain
# extractable. Such an image passes `command -v gs` and still ships the
# interpreter. Install, purge, and verification are therefore chained here.
# DO NOT split this for readability.
#
# The tree is named EXPLICITLY rather than left to `--auto-remove`. The
# installer marks everything it pulls in as manually installed - `apt-mark
# showmanual` lists ghostscript, libgs10, libgs10-common, libgs-common and
# poppler-data - and --auto-remove only reclaims auto-marked packages, so on its
# own it frees 187 kB and leaves 38 MB of Ghostscript libraries behind. It is
# kept here only to catch anything genuinely orphaned. When trixie's Ghostscript
# major changes, `libgs10*` stops resolving and this build fails loudly, which
# is the intended behaviour (spec §17 q2), not a reason to soften it.
#
# fonts-urw-base35 is deliberately NOT purged. Despite §3.2 listing it, it is
# not Ghostscript baggage: libmagickcore-7.q16-10 recommends it, and it is
# ImageMagick's standard PostScript-35 font set. Removing it would save 15.5 MB
# and silently break text annotation for anyone not naming a font explicitly.
#
# The survivor check must NOT glob `libgs*`: that also matches libgssapi-krb5-2,
# an unrelated Kerberos library that other packages need, so the assertion could
# never pass. `libgs[0-9]*` plus libgs-common is the correct pattern.
#
# Every negative assertion is written `if cond; then exit 1; fi` rather than
# `! cond`, because `set -e` never exits on a status inverted with `!`.
#
# SC2016 is suppressed deliberately: `$e` below is a PHP variable, and the
# single quotes are what stop the shell from expanding it before PHP sees it.
# Double quotes here would be the bug the rule thinks it is preventing.
# hadolint ignore=SC2016
RUN set -eux; \
    install-php-extensions \
      bcmath exif gd imagick intl opcache pcntl \
      pdo_mysql pdo_pgsql redis sockets zip; \
    apt-get update; \
    apt-get purge -y --auto-remove \
      ghostscript libgs10 libgs10-common libgs-common poppler-data; \
    if command -v gs >/dev/null 2>&1; then echo "FAIL: gs is still on PATH" >&2; exit 1; fi; \
    if [ -e /usr/bin/gs ]; then echo "FAIL: /usr/bin/gs still exists" >&2; exit 1; fi; \
    gs_left="$(dpkg-query -W -f='${binary:Package} ${Status}\n' \
      ghostscript 'libgs[0-9]*' libgs-common poppler-data 2>/dev/null || true)"; \
    case "$gs_left" in \
      *'ok installed'*) echo "FAIL: Ghostscript tree survives: $gs_left" >&2; exit 1 ;; \
    esac; \
    php -r 'foreach (["pcntl", "posix", "imagick"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "FAIL: extension $e is not loaded\n"); exit(1); } }'; \
    php -r '$f = array_map("strtoupper", Imagick::queryFormats()); foreach (["JPEG","PNG","WEBP"] as $x) { if (!in_array($x, $f, true)) { fwrite(STDERR, "FAIL: imagick lost $x\n"); exit(1); } }'; \
    rm -rf /var/lib/apt/lists/* /usr/local/bin/install-php-extensions

# ---------------------------------------------------------------------------
# RUN 2 - BOUNDARY: identity only. Kept out of the extension layer so that
# changing the UID does not invalidate an expensive rebuild.
#
# The base has www-data at 33 and nothing at 1000, but that is an observation,
# not a guarantee. A collision must fail the build - `|| true` here would ship
# an image whose UID silently differs from the contract.
#
# /var/www/html exists in the fpm base as www-data:www-data mode 1777. chown
# alone would leave it world-writable, so the mode is reset too.
#
# `useradd -l` (--no-log-init) skips lastlog/faillog initialisation. At UID 1000
# it changes nothing, but USER_UID is a build arg: without -l, a consumer
# building with a high UID gets a sparse lastlog expanded to gigabytes in the
# layer. Nothing in a container reads lastlog anyway.
#
# The LaraOCI assets directory (§6.1) is created HERE, with an explicit 0755,
# rather than being left to the COPY that fills it. BuildKit applies a COPY's
# --chmod to the parent directories it creates as well as to the file, so
# `COPY --chmod=0644 x /usr/local/share/laraoci/templates/` yields drw-r--r--
# directories that only root can traverse - every non-root read then fails with
# "Permission denied" while the file mode itself looks perfectly correct.
RUN set -eux; \
    if getent group "${USER_GID}" >/dev/null; then \
      echo "FAIL: GID ${USER_GID} already exists: $(getent group "${USER_GID}")" >&2; exit 1; fi; \
    if getent passwd "${USER_UID}" >/dev/null; then \
      echo "FAIL: UID ${USER_UID} already exists: $(getent passwd "${USER_UID}")" >&2; exit 1; fi; \
    groupadd -g "${USER_GID}" "${USER_NAME}"; \
    useradd -l -u "${USER_UID}" -g "${USER_GID}" -m -s /bin/sh "${USER_NAME}"; \
    mkdir -p /var/www/html; \
    chown "${USER_UID}:${USER_GID}" /var/www/html; \
    chmod 0755 /var/www/html; \
    install -d -m 0755 /usr/local/share/laraoci/templates; \
    test "$(id -u "${USER_NAME}")" = "${USER_UID}"; \
    test "$(id -g "${USER_NAME}")" = "${USER_GID}"

COPY config/imagemagick/policy.xml /tmp/policy.xml

# ---------------------------------------------------------------------------
# RUN 3 - BOUNDARY: must come AFTER the extension install, because
# /etc/ImageMagick-* does not exist until imagick pulls ImageMagick in (trap 4).
# Separate from RUN 1 so that editing the policy is a cheap rebuild.
#
# The directory is detected, not hardcoded: trixie is ImageMagick 7 today and
# the point of detection is surviving the suite bump that changes it. Detection
# that finds nothing must FAIL - a silently policy-less imagick is precisely
# the ImageTragick surface D13 exists to remove.
#
# The assertion checks the RESOURCE limit first. That is the robust canary: if
# ImageMagick's tokenizer rejects the file it loads an empty policy and silently
# allows everything, and the memory limit reverts to a host-derived default. A
# single backtick in the file is enough to cause that.
#
# The PDF probe file must EXIST. A missing path throws "unable to open image",
# which is an ImagickException too - so asserting only that an exception is
# raised (as §10.1 suggests) passes even with no policy at all.
#
# @-prefixed indirect reads are NOT asserted: ImageMagick 7 fails them with "no
# decode delegate" rather than a policy denial, so the path rule cannot be
# proven this way. MVG and TEXT are asserted instead - they do go through the
# coder policy.
# hadolint ignore=SC2016
RUN set -eux; \
    found=''; \
    for d in /etc/ImageMagick-7 /etc/ImageMagick-6; do \
      if [ -d "$d" ]; then install -m 0644 -o root -g root /tmp/policy.xml "$d/policy.xml"; found="$d"; fi; \
    done; \
    if [ -z "$found" ]; then \
      echo "FAIL: no /etc/ImageMagick-* directory - refusing to ship imagick without a policy" >&2; exit 1; fi; \
    echo "laraoci: ImageMagick policy installed to $found"; \
    rm /tmp/policy.xml; \
    php -r '$f = "/tmp/laraoci-policy-check"; file_put_contents($f, "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n"); $mem = (int) Imagick::getResourceLimit(Imagick::RESOURCETYPE_MEMORY); if ($mem !== 256 * 1048576) { fwrite(STDERR, "FAIL: policy.xml was not parsed - memory limit is $mem, expected " . (256 * 1048576) . "\n"); exit(1); } foreach (["PDF:$f", "MVG:$f", "TEXT:$f"] as $spec) { try { (new Imagick())->readImage($spec); fwrite(STDERR, "FAIL: $spec was ALLOWED\n"); exit(1); } catch (ImagickException $e) { if (!preg_match("/(security policy|not authoriz)/i", $e->getMessage())) { fwrite(STDERR, "FAIL: $spec threw without a policy message: " . $e->getMessage() . "\n"); exit(1); } } } unlink($f); echo "laraoci: policy verified live (memory limit and PDF/MVG/TEXT denials)\n";'

COPY --chmod=0644 config/php/zz-laraoci.ini.template /usr/local/share/laraoci/templates/

# The §6.4 defaults live here and nowhere else: visible to `docker inspect`,
# inherited by every descendant, and overridable per container. The entrypoint
# reads them rather than carrying a second copy of the defaults.
#
# PHP_OPCACHE_PRELOAD is deliberately unset (§6.4) - preload is opt-in (D14),
# and per 🧭 4 the entrypoint only honours it for FPM.
# PHP_MEMORY_LIMIT / PHP_MAX_EXECUTION_TIME carry the FPM values; M2's cli image
# overrides them to 512M / 0 (§6.4).
# LARAOCI_PRELOAD_* are M3's (LOCI-035) - the preload script does not ship yet,
# so setting them now would be inert configuration.
#
# thread=1 in the ImageMagick policy plus MAGICK_THREAD_LIMIT is a correctness
# fix as much as a security one: OpenMP pools are per process, so twenty FPM
# children each opening one will thrash a CPU-limited container (§3.2).
ENV PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=30 \
    PHP_UPLOAD_MAX_FILESIZE=16M \
    PHP_POST_MAX_SIZE=16M \
    PHP_OPCACHE_ENABLE=1 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
    PHP_OPCACHE_MEMORY_CONSUMPTION=192 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=20000 \
    MAGICK_THREAD_LIMIT=1 \
    MAGICK_TMPDIR=/tmp

WORKDIR /var/www/html

USER ${USER_NAME}
