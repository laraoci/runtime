setup() {
  YQ() { yq "$@" config/images.yml; }
}

@test "config: exactly six images with parent edges" {
  run bash -c "yq -r '.images | keys | length' config/images.yml"
  [ "$status" -eq 0 ]
  [ "$output" -eq 6 ]
}

@test "config: exactly one php version is default" {
  run bash -c "yq -r '[.php[] | select(.default == true)] | length' config/images.yml"
  [ "$output" -eq 1 ]
}

@test "config: default php version is 8.4" {
  run bash -c "yq -r '.php | to_entries | map(select(.value.default == true))[0].key' config/images.yml"
  [ "$output" = "8.4" ]
}

@test "config: parent edges match the catalog (D1)" {
  run bash -c "yq -r '.images.fpm.parent' config/images.yml"
  [ "$output" = "runtime" ]
  run bash -c "yq -r '.images.queue.parent' config/images.yml"
  [ "$output" = "cli" ]
  run bash -c "yq -r '.images.scheduler.parent' config/images.yml"
  [ "$output" = "cli" ]
}

@test "config: twelve core extensions" {
  run bash -c "yq -r '.extensions.core | length' config/images.yml"
  [ "$output" -eq 12 ]
}

@test "config: every image has a size budget" {
  run bash -c "yq -r '[ . as \$d | \$d.images | keys[] as \$k | select((\$d.size_budgets | has(\$k)) | not) ] | length' config/images.yml"
  [ "$output" -eq 0 ]
}

@test "config: fpm declares the SIGQUIT stop signal, and nothing else declares one (§6.2)" {
  # php-fpm drains on SIGQUIT and dies on SIGTERM; the CLI images are the other
  # way round and inherit runtime's SIGTERM. If this key ever spreads to another
  # image, that image's workers stop trapping their own shutdown.
  run yq -r '.images.fpm.stopsignal' config/images.yml
  [ "$output" = "SIGQUIT" ]

  run yq -r '[.images | to_entries | .[] | select(.value.stopsignal) | .key] | join(",")' config/images.yml
  [ "$output" = "fpm" ]
}

@test "config: every image carries a description for its OCI label" {
  run bash -c "yq -r '[.images[] | select((.description // \"\") == \"\")] | length' config/images.yml"
  [ "$output" -eq 0 ]
}

@test "config: no script interpolates a value into a yq expression" {
  # bin/build-chain.sh, bin/size-check.sh and bin/structure-test.sh all state
  # this rule in comments; four sites did the opposite, and two of them
  # (tests/smoke/run.sh) queried with an unvalidated --php argument. strenv()
  # passes the value through the environment, where it can never be read as
  # query syntax.
  #
  # The pattern is a double quote immediately followed by a $ inside a yq
  # expression: .php."$php", .size_budgets."$image".
  local hits
  hits="$(grep -rn 'yq[^|]*\."\$' --include='*.sh' --include='*.yml' \
    bin tests/smoke .github/workflows || true)"
  if [ -n "$hits" ]; then
    echo "value interpolated into a yq expression - use strenv() instead:" >&2
    echo "$hits" >&2
    false
  fi
}

@test "config: no image description spans more than one line" {
  # An OCI label is single-line by definition, and build.yml writes this value
  # into $GITHUB_OUTPUT as `description=<value>`. A literal-block scalar there
  # injects arbitrary key=value pairs into that step's outputs - including
  # base_digest, which the same step emits and which feeds both the BASE_DIGEST
  # build argument and org.opencontainers.image.base.digest.
  run yq -r '.images | to_entries | .[]
    | select((.value.description // "") | test("\n")) | .key' config/images.yml
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "config: the ImageMagick policy contains no backtick" {
  # policy.xml's own header: ImageMagick's policy reader is a hand-rolled
  # tokenizer, not an XML parser. A backtick anywhere - including inside a
  # comment - is read as a string delimiter, the rest of the file is swallowed,
  # and an EMPTY policy loads. An empty policy allows everything, and nothing
  # warns. The build's live canary catches it; this catches it sooner and free.
  run grep -c '`' config/imagemagick/policy.xml
  [ "$output" -eq 0 ]
}
