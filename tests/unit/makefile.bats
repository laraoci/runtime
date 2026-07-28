# The Makefile is convenience-only: every recipe must be a SINGLE delegation to
# bin/*.sh or to an already-pinned tool, never logic of its own. bin/*.sh is
# tested (tests/unit) and CI calls it directly; a recipe that grew real
# behaviour would be untested code on a second execution path. These tests keep
# the Makefile honest so it stays sugar and never becomes a fork of the logic.

# Recipe lines for a target: the tab-indented block after `target:`.
recipe_lines() {
  awk -v t="$1" '
    $0 ~ "^" t ":" { grab = 1; next }
    grab && /^\t/   { sub(/^\t/, ""); print; next }
    grab            { grab = 0 }
  ' Makefile
}

@test "makefile: exists and is tab-indented (no spaces-as-recipe)" {
  [ -f Makefile ]
  # A recipe line indented with spaces is the classic silent Makefile break.
  run grep -nP '^    ' Makefile
  [ "$status" -ne 0 ]
}

@test "makefile: every documented target actually exists as a rule" {
  # Each `## `-documented target in help must be a real .PHONY rule, or help
  # advertises something that errors.
  local t
  for t in $(grep -oE '^[a-z][a-z-]*:.*## ' Makefile | cut -d: -f1); do
    grep -qE "^\.PHONY:.*\b$t\b" Makefile || {
      echo "target '$t' is documented but not in .PHONY" >&2
      false
    }
  done
}

@test "makefile: action recipes delegate to bin/ or a pinned tool, nothing else" {
  # The core invariant. Every recipe line of an action target must start with a
  # known delegate: a bin/ script, the pinned bats/shellcheck/shfmt, or the
  # fetch-bats path expansion. Pure-output targets (help, hooks) are exempt -
  # they only printf.
  local allowed='^(bin/|shellcheck |shfmt |\$\(BATS\)|\$\{BATS\})'
  local target line
  for target in test lint fmt fmt-fix matrix affected sizes structure; do
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if ! printf '%s' "$line" | grep -qE "$allowed"; then
        echo "recipe for '$target' is not a bare delegation: $line" >&2
        false
      fi
    done < <(recipe_lines "$target")
  done
}

@test "makefile: no recipe chains commands (one delegation per line)" {
  # && / ; / | inside a recipe means logic is accreting. The one intentional
  # exception is help/hooks, which are pure printf and not checked here.
  local target line
  for target in test lint fmt fmt-fix matrix affected sizes structure; do
    while IFS= read -r line; do
      case "$line" in
        *' && '* | *';'* | *' | '*)
          echo "recipe for '$target' chains commands - move logic into bin/: $line" >&2
          false
          ;;
      esac
    done < <(recipe_lines "$target")
  done
}

@test "makefile: no target duplicates matrix/affected graph logic" {
  # A recipe must never call yq/jq against images.yml itself; that is
  # read_image_graph's job, reached only through bin/. Catches the tempting
  # `yq ... images.yml` one-liner that would fork the graph parser.
  #
  # Matched on recipe lines (leading whitespace) without relying on \t inside an
  # -E class, which is non-portable; [[:space:]] and two plain greps do it.
  local line
  while IFS= read -r line; do
    case "$line" in
      [[:space:]]*) : ;;
      *) continue ;;
    esac
    if printf '%s' "$line" | grep -Eq '(yq|jq)' && printf '%s' "$line" | grep -q 'images.yml'; then
      echo "recipe reparses images.yml directly - use bin/matrix.sh: $line" >&2
      false
    fi
  done < Makefile
}
