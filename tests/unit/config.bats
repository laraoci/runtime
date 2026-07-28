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
