# imagick operation and policy denial, through FPM (LOCI-031, spec §10.2 step 6).
#
# WHY THROUGH FPM WHEN THE STRUCTURE TESTS ALREADY COVER IMAGICK. They cover it
# on the CLI SAPI, in a one-shot `php -r` process started by the test itself.
# This asserts the same two claims about a pooled FPM worker: a different SAPI,
# a long-lived process reused across requests, and the MAGICK_THREAD_LIMIT the
# image sets because twenty workers each opening an OpenMP pool will thrash a
# CPU-limited container. A policy that is read for one and not the other, or an
# extension that works once and not on the second request through the same
# worker, passes there and fails here.
#
# The two claims are opposites and both matter: imagick must WORK (a policy that
# denies everything is not hardening, it is a broken image) and it must REFUSE
# the coders D13 blocks.
#
# @file indirect reads are deliberately not asserted. ImageMagick 7 rejects them
# with "no decode delegate" before the path policy is ever consulted, so the
# assertion would prove nothing about pattern="@*" - established during the M1
# runtime work.

load helpers

setup_file() {
  require_smoke_env || return 1

  # Every route below is a Laravel route; without vendor/ they 500 and this
  # suite would report a policy failure that is really a missing install.
  ensure_app_installed || return 1

  http_get resize /imagick/resize

  # One request per coder rather than one loop inside a case, so a coder that
  # regresses is named in the failing test rather than buried in a loop index.
  http_get policy_pdf /imagick/policy/PDF
  http_get policy_mvg /imagick/policy/MVG
  http_get policy_text /imagick/policy/TEXT

  # Asserted against the RUNNING container, not the built image. Ghostscript is
  # purged in runtime's RUN 1 (it is the delegate that turns a PDF read into
  # arbitrary code execution), and the check belongs here because a base image
  # change, a stray apt dependency pulled in by a later layer, or a consumer's
  # own RUN could reintroduce it without touching that RUN.
  capture gs_on_path compose exec -T fpm sh -c 'command -v gs || echo ABSENT'
  capture gs_file compose exec -T fpm sh -c 'test -e /usr/bin/gs && echo PRESENT || echo ABSENT'
}

# The policy denial cases all make the same two-part claim, so they share one
# assertion: the route reported a denial, AND the reason was the security
# policy.
#
# THE SECOND HALF IS THE WHOLE TEST, and that was established by deleting
# /etc/ImageMagick-7/policy.xml from a throwaway image and running this suite
# against it. What the three coders do with no policy at all:
#
#   PDF   DENIED:FailedToExecuteCommand `'gs' -sstdout=%stderr -dQUIET ...
#   MVG   DENIED:must specify image size `/tmp/probe' @ error/mvg.c/...
#   TEXT  ALLOWED
#
# Only TEXT is caught by a `DENIED:*` check. PDF fails because Ghostscript was
# purged and MVG fails because a fake PDF is not valid MVG - both report a
# denial, neither has anything to do with the coder policy, and a case
# satisfied by the DENIED prefix alone would report green on an image that
# hardens nothing. Requiring the MESSAGE to name the policy is what separates
# "this coder is blocked" from "this coder happened to fail today".
assert_denied_by_policy() {
  local name="$1" coder="$2"
  local body
  body="$(http_body "$name")"

  if [ "$(http_code "$name")" != "200" ]; then
    echo "GET /imagick/policy/$coder returned $(http_code "$name")" >&2
    dump_app_errors
    return 1
  fi

  if [[ "$body" == ALLOWED* ]]; then
    echo "$coder was ALLOWED - the ImageMagick policy is not in effect" >&2
    return 1
  fi

  [[ "$body" == DENIED:* ]]
  [[ "$body" == *"not authorized"* || "$body" == *"security policy"* ]]
}

@test "imagick resizes a JPEG through the FPM SAPI" {
  # The positive half. A policy strict enough to break ordinary image work would
  # satisfy every denial case below while making the image useless, so this runs
  # first and is not optional.
  local code
  code="$(http_code resize)"
  if [ "$code" != "200" ]; then
    echo "GET /imagick/resize returned $code" >&2
    dump_app_errors
  fi
  [ "$code" = "200" ]

  # The dimensions, not merely a 200: the route creates an image in memory,
  # resizes it and reports what it measured afterwards, so this is the codec
  # path having actually run rather than a handler that returned a string.
  [[ "$(http_body resize)" == *"resized=50x50"* ]]
}

@test "the PDF coder is denied by policy through the FPM SAPI" {
  assert_denied_by_policy policy_pdf PDF
}

@test "the MVG coder is denied by policy through the FPM SAPI" {
  assert_denied_by_policy policy_mvg MVG
}

@test "the TEXT coder is denied by policy through the FPM SAPI" {
  assert_denied_by_policy policy_text TEXT
}

@test "Ghostscript is absent from the running fpm container" {
  assert_step_ok gs_on_path
  [[ "$(step_output gs_on_path)" == *"ABSENT"* ]]
}

@test "no Ghostscript binary survives at /usr/bin/gs" {
  # PATH and the filesystem are separate claims. A gs that exists but is not on
  # PATH is still reachable by anything that calls it absolutely - including
  # ImageMagick's own delegate table, which does exactly that.
  assert_step_ok gs_file
  [ "$(step_output gs_file)" = "ABSENT" ]
}
