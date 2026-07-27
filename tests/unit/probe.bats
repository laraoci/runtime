# tests/probe/no-extra.Dockerfile measures a size delta by building twice from
# one file. Its RUN 1 must mirror the real image's RUN 1 or the delta stops
# describing what ships. That is not hypothetical: the first version of the
# probe drifted, still carried 38 MB of libgs, and measured the "smaller"
# no-extra variant as LARGER (docs/size-report-m1.md). Assert the agreement.

REAL=images/runtime/Dockerfile
PROBE=tests/probe/no-extra.Dockerfile

# Collapse backslash continuations so each Dockerfile instruction is one line.
flatten() {
  sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$1"
}

# The extension list handed to install-php-extensions, sorted and deduplicated.
# Anchored to ^RUN so the `COPY --from=...` line is ignored, and the pattern
# requires a trailing space so the `rm -rf .../install-php-extensions` at the
# end of the same instruction does not match.
extensions_of() {
  flatten "$1" | grep '^RUN' | grep -o 'install-php-extensions [^;]*' \
    | tr -s ' \t' '\n' | grep -v '^install-php-extensions$' | grep -v '^$' \
    | sort -u | tr '\n' ' '
}

# The Ghostscript tree named in the first apt-get purge.
purge_of() {
  flatten "$1" | grep '^RUN' | grep -o 'apt-get purge -y --auto-remove [^;]*' | head -1 \
    | sed 's/apt-get purge -y --auto-remove //' \
    | tr -s ' \t' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
}

@test "probe: the extension list mirrors the runtime Dockerfile (R4)" {
  [ "$(extensions_of "$PROBE")" = "$(extensions_of "$REAL")" ]
}

@test "probe: the Ghostscript purge list mirrors the runtime Dockerfile (R4)" {
  # This is the exact assertion that would have caught the original drift.
  [ "$(purge_of "$PROBE")" = "$(purge_of "$REAL")" ]
}

@test "probe: the runtime Dockerfile installs exactly extensions.core (R4)" {
  config_list="$(yq -r '.extensions.core | sort | .[]' config/images.yml | tr '\n' ' ')"
  [ "$(extensions_of "$REAL")" = "$config_list" ]
}

@test "probe: the extractor is not silently matching nothing" {
  # A regex that stops matching would make all three tests above pass vacuously.
  [ -n "$(extensions_of "$REAL")" ]
  [ -n "$(purge_of "$REAL")" ]
  [[ "$(extensions_of "$REAL")" == *"imagick"* ]]
  [[ "$(purge_of "$REAL")" == *"ghostscript"* ]]
}
