setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/structure" "$TMP/bin"
  cat >"$TMP/bin/fake-cst" <<'FAKE'
#!/usr/bin/env bash
echo "cst called: $*"
FAKE
  chmod +x "$TMP/bin/fake-cst"
  export LARAOCI_CST_CMD="$TMP/bin/fake-cst"
}

teardown() {
  rm -rf "$TMP"
}

@test "structure-test: no config for the image is a no-op, not a failure" {
  run bin/structure-test.sh --image cli --ref ghcr.io/laraoci/cli:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no config"* ]]
}

@test "structure-test: runs the checker when a config exists" {
  touch "$TMP/structure/runtime.yaml"
  run bin/structure-test.sh --image runtime --ref ghcr.io/laraoci/runtime:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cst called: test --image ghcr.io/laraoci/runtime:8.4-trixie --config $TMP/structure/runtime.yaml"* ]]
}

@test "structure-test: --image is required" {
  run bin/structure-test.sh --ref ghcr.io/laraoci/runtime:8.4-trixie
  [ "$status" -eq 2 ]
}

@test "structure-test: --ref is required" {
  run bin/structure-test.sh --image runtime
  [ "$status" -eq 2 ]
}

@test "structure-test: an unknown argument fails loudly" {
  run bin/structure-test.sh --image runtime --ref x --nope
  [ "$status" -eq 2 ]
}
