# tests/smoke/run.sh owns the stack; these are the assertions about it that need
# no stack. All three are STATIC (D24): a smoke leg costs minutes and an image
# build, so "the harness does not build an image its own compose file resolves"
# must fail in the unit suite, not four minutes into a leg.

@test "smoke: run.sh builds every laraoci image compose.yml can resolve" {
  # THE FINDING. compose.yml declares queue and scheduler with `image:` and no
  # `build:` key, so a missing tag is not a build error - compose PULLS it, and
  # nothing is published until M4 (D27). The leg then fails with "manifest
  # unknown", which reads like a registry outage. It passed locally only because
  # the daemon still held hand-built M3 tags.
  local declared want img
  declared="$(sed -n 's/^smoke_images=(\(.*\))$/\1/p' tests/smoke/run.sh)"
  [ -n "$declared" ]

  # Every service whose image comes from OUR registry. nginx is excluded by the
  # filter rather than by name: it is pinned by digest and nothing builds it.
  want="$(yq -r '.services | to_entries | .[]
    | select((.value.image // "") | test("LARAOCI_REGISTRY"))
    | .value.image' tests/smoke/compose.yml |
    sed -E 's#^[^/]*/([a-z0-9-]+):.*#\1#' | sort -u)"
  [ -n "$want" ]

  while IFS= read -r img; do
    [ -z "$img" ] && continue
    case " $declared " in
      *" $img "*) : ;;
      *)
        echo "compose.yml resolves '$img' but tests/smoke/run.sh does not build it" >&2
        echo "run.sh builds: $declared" >&2
        false
        ;;
    esac
  done <<<"$want"
}

@test "smoke: every image the harness builds is an image in config/images.yml" {
  # The other direction: a typo in the list would fail inside build-chain.sh with
  # a less obvious message, and only after the first three images had built.
  local declared img
  declared="$(sed -n 's/^smoke_images=(\(.*\))$/\1/p' tests/smoke/run.sh)"
  for img in $declared; do
    run bash -c "IMG='$img' yq -r '.images | has(strenv(IMG))' config/images.yml"
    [ "$output" = "true" ]
  done
}

@test "smoke: the harness asserts each image is local before running any suite" {
  # bin/structure-test.sh:130 makes the same assertion for the same reason: a tag
  # compose cannot find is PULLED, so the failure surfaces a long way from its
  # cause. Ordering is the assertion - a guard after the suites guards nothing.
  local guard bats_call
  guard="$(grep -n 'docker image inspect' tests/smoke/run.sh | head -1 | cut -d: -f1)"
  bats_call="$(grep -n '"\$bats_bin"' tests/smoke/run.sh | head -1 | cut -d: -f1)"
  [ -n "$guard" ]
  [ -n "$bats_call" ]
  ((guard < bats_call))
}
