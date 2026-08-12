#!/usr/bin/env bats

# THE MECHANISM, NOT THE FLAG. workflows.bats proves the stamp is declared,
# referenced and plumbed. This file proves the thing that actually has to be
# true: a changed REBUILD_STAMP makes BuildKit RE-EXECUTE the instruction, and
# an unchanged one lets it restore from cache. It builds a four-line fixture
# rather than images/runtime/Dockerfile because the real RUN 1 installs twelve
# PHP extensions and this is a unit test - the CACHING BEHAVIOUR is identical,
# because it is a property of how BuildKit keys a RUN on its expanded command
# string, not of what the command does.
#
# The full-scale proof, against the real image and a real Debian update, is the
# §9.3 acceptance test at 🚦 Gate 2 (docs/m5-rebuild-acceptance.md). This is the
# one that runs on every PR.

setup() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker buildx version >/dev/null 2>&1 || skip "buildx not available"
  TMP="$(mktemp -d)"
  BUILDER="laraoci-cachetest-$$"
  docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
  cat > "$TMP/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1
FROM busybox:1.37
ARG REBUILD_STAMP=""
RUN set -eux; \
    : "REBUILD_STAMP=${REBUILD_STAMP}"; \
    date +%s%N > /marker
EOF
}

teardown() {
  [ -n "${BUILDER:-}" ] && docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Build once and return the /marker the RUN wrote. A re-executed layer writes a
# new nanosecond timestamp; a restored one carries the old file forward.
marker() {
  local stamp="$1" iid
  iid="laraoci-cachetest:$RANDOM$RANDOM"
  docker buildx build --builder "$BUILDER" \
    --build-arg "REBUILD_STAMP=$stamp" \
    --cache-from "type=local,src=$TMP/cache" \
    --cache-to "type=local,dest=$TMP/cache,mode=max" \
    --load -t "$iid" "$TMP" >/dev/null 2>&1
  docker run --rm --entrypoint cat "$iid" /marker
  docker image rm -f "$iid" >/dev/null 2>&1
}

@test "rebuild-cache: an UNCHANGED stamp restores the layer from cache" {
  local a b
  a="$(marker '')"
  b="$(marker '')"
  [ "$a" = "$b" ] || {
    echo "the layer re-executed with an unchanged stamp - the release path would" >&2
    echo "cold-build every week, which is the cost D41 declined to pay" >&2
    false
  }
}

@test "rebuild-cache: a CHANGED stamp re-executes the layer (§9.3, D41)" {
  local a b
  a="$(marker '')"
  b="$(marker '20260817')"
  [ "$a" != "$b" ] || {
    echo "the layer was RESTORED FROM CACHE despite a changed REBUILD_STAMP." >&2
    echo "This is the silent-success failure §9.3 exists to prevent: the rebuild" >&2
    echo "would report green while apt-get -y upgrade never ran." >&2
    false
  }
}

@test "rebuild-cache: two different stamps are two different layers" {
  # The stamp is a DATE, so consecutive weeks must not collide.
  local a b
  a="$(marker '20260817')"
  b="$(marker '20260824')"
  [ "$a" != "$b" ]
}
