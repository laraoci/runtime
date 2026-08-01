#!/usr/bin/env bash

# Sourced by bin/matrix.sh, bin/affected.sh, bin/size-check.sh.
# Not executed directly; inherits `set -euo pipefail` from the caller.

# CONFIG can be overridden (used by tests with fixtures); defaults to the
# single source of truth.
: "${CONFIG:=config/images.yml}"

# THE PINNED yq, resolved through the verified fetcher - not PATH. This is the
# same change bin/structure-test.sh made for container-structure-test, and for a
# stronger reason: yq decides the build matrix, the topological order, the uid and
# gid baked into every image, the registry, the Debian suite, the OCI description
# and the size budgets. It was pinned in tools.env by SHA-256 and then every
# consumer used whatever copy the machine happened to have, with
# require_mikefarah_yq checking the FLAVOUR and never the version. A GitHub
# runner's preinstalled copy was a third version again.
#
# YQ= in the environment is the override seam - a consumer with their own verified
# copy, or a test. Empty means "resolve through bin/fetch-tools.sh".
#
# The fetcher's own progress line is suppressed because this runs on every source,
# including inside loops; a FAILURE is fatal and names the command that prints the
# reason, so nothing is silently swallowed.
: "${YQ:=}"
if [[ -z "$YQ" ]]; then
  if ! YQ="$("$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fetch-tools.sh" --path yq 2>/dev/null)" ||
    [[ -z "$YQ" ]]; then
    echo "error: could not resolve the pinned yq through bin/fetch-tools.sh." >&2
    echo "       run 'bin/fetch-tools.sh yq' to see why (network, checksum or arch)," >&2
    echo "       or set YQ=/path/to/yq to use your own verified copy." >&2
    exit 1
  fi
fi
export YQ

# Fail loudly if $YQ is the wrong yq. mikefarah/yq (Go) is what every expression
# in this repository is written against; kislyuk/yq is a Python wrapper around jq
# with an incompatible syntax. Assert the flavour rather than producing confusing
# downstream failures - it still matters, because YQ= can point anywhere.
require_mikefarah_yq() {
  if ! command -v "$YQ" >/dev/null 2>&1; then
    echo "error: '$YQ' not found. Run 'make tools', or set YQ=/path/to/yq" >&2
    echo "       (mikefarah/yq v4: https://github.com/mikefarah/yq)" >&2
    exit 1
  fi

  if ! "$YQ" --version 2>&1 | grep -qi mikefarah; then
    echo "error: '$YQ' is the wrong yq. This project requires mikefarah/yq v4 (Go)," >&2
    echo "       not kislyuk/yq (the Python jq wrapper); their syntaxes differ." >&2
    echo "       found: $("$YQ" --version 2>&1)" >&2
    exit 1
  fi
}

# Guard for an option that takes a value. Without it, `--image` with nothing
# after it dies on `$2: unbound variable` under `set -u` and exits 1, where
# every other usage error in this project exits 2.
#
# Call as: require_arg "$1" "${2:-}"
# The `${2:-}` is required at the call site - a bare "$2" would trip `set -u`
# before this function is ever entered.
require_arg() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

# The image graph, read in ONE yq call and validated once, so that matrix.sh and
# affected.sh cannot disagree about whether config/images.yml is well-formed.
#
# Populates:
#   IMAGE_NAMES      indexed array, file order
#   IMAGE_ORDER      indexed array, topologically sorted (parents first)
#   IMAGE_PARENT     name -> parent ("" for the root)
#   IMAGE_DOCKERFILE name -> dockerfile path
#   IMAGE_PLATFORMS  name -> comma-joined override ("" means use the defaults)
declare -a IMAGE_NAMES=() IMAGE_ORDER=()
declare -A IMAGE_PARENT=() IMAGE_DOCKERFILE=() IMAGE_PLATFORMS=()

read_image_graph() {
  IMAGE_NAMES=()
  IMAGE_ORDER=()
  IMAGE_PARENT=()
  IMAGE_DOCKERFILE=()
  IMAGE_PLATFORMS=()

  local name parent dockerfile platforms
  # Process substitution, not a pipe: the loop must run in THIS shell or the
  # arrays it fills disappear with the subshell.
  #
  # yq emits ONE FIELD PER LINE and this reads four at a time, rather than
  # splitting a delimited row. That is load-bearing, not style.
  #
  # `@tsv` + `IFS=$'\t'` looks like the obvious choice and is wrong: tab is an
  # IFS *whitespace* character, so bash collapses a run of adjacent tabs into a
  # single delimiter. `runtime<TAB><TAB>images/runtime/Dockerfile` splits into
  # TWO fields, not three, putting the dockerfile path into `parent`. The root
  # image is the only one with an empty parent, so exactly one row broke and the
  # graph rejected its own config with "names parent 'images/runtime/Dockerfile'".
  #
  # A non-whitespace delimiter (0x1f) fixes the collapsing but puts an invisible
  # control byte in this file, which diffs hide and a copy-paste can silently
  # drop. One field per line needs no delimiter at all. `IFS=` disables read's
  # leading/trailing whitespace trimming so a value is taken exactly as emitted.
  while IFS= read -r name && IFS= read -r parent &&
    IFS= read -r dockerfile && IFS= read -r platforms; do
    [[ -z "$name" ]] && continue
    # An image name reaches a shell command line, a registry reference and a CI
    # matrix leg. Validate it at the source rather than escaping it at each use.
    if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "error: invalid image name '$name' in $CONFIG" >&2
      echo "       names must match ^[a-z0-9]([a-z0-9-]*[a-z0-9])?\$" >&2
      exit 1
    fi
    IMAGE_NAMES+=("$name")
    IMAGE_PARENT["$name"]="$parent"
    # SC2034: shellcheck analyses one file at a time, so it cannot see that
    # bin/matrix.sh - which sources this file - reads both of these. It fires on
    # exactly the two globals nothing in HERE reads; the other three are used by
    # the validation and topological sort below and need no suppression.
    # shellcheck disable=SC2034
    IMAGE_DOCKERFILE["$name"]="$dockerfile"
    # shellcheck disable=SC2034
    IMAGE_PLATFORMS["$name"]="$platforms"
  done < <("$YQ" -r '
    .images | to_entries | .[]
    | [.key, (.value.parent // ""), (.value.dockerfile // ""),
       (.value.platforms // [] | join(","))]
    | .[]' "$CONFIG")

  if ((${#IMAGE_NAMES[@]} == 0)); then
    echo "error: $CONFIG defines no images" >&2
    exit 1
  fi

  local img p
  for img in "${IMAGE_NAMES[@]}"; do
    p="${IMAGE_PARENT[$img]}"
    if [[ -n "$p" && -z "${IMAGE_PARENT[$p]+set}" ]]; then
      echo "error: image '$img' names parent '$p', which is not an image in $CONFIG" >&2
      exit 1
    fi
  done

  # Kahn-style topological sort: emit an image once its parent has been emitted.
  # Build order must never be hand-maintained. A pass that emits nothing means a
  # cycle - dangling parents were already rejected above.
  local -A emitted=()
  local progress
  while ((${#IMAGE_ORDER[@]} < ${#IMAGE_NAMES[@]})); do
    progress=0
    for img in "${IMAGE_NAMES[@]}"; do
      [[ -n "${emitted[$img]:-}" ]] && continue
      p="${IMAGE_PARENT[$img]}"
      if [[ -z "$p" || -n "${emitted[$p]:-}" ]]; then
        IMAGE_ORDER+=("$img")
        emitted["$img"]=1
        progress=1
      fi
    done
    ((progress)) || {
      echo "error: cycle in the images graph in $CONFIG" >&2
      exit 1
    }
  done
}
