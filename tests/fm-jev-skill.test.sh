#!/usr/bin/env bash
# Offline behavior tests for the vendored Jev client (.agents/skills/jev/jev.py).
# Both cases run with no network and no real key: they pin the client's failure
# contract (exit code plus a readable error instead of a traceback), never the
# live API, which CI can neither reach nor authenticate against.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JEV_SRC="$ROOT/.agents/skills/jev/jev.py"
TMP_ROOT=$(fm_test_tmproot fm-jev-skill)
REQUEST='{"state":"offline test","questions":{"q":{"type":"noul","instructions":"Is this a test?","criteria":{"true":"yes","false":"no"}}}}'

command -v python3 >/dev/null 2>&1 || fail "python3 not found; the jev client needs it"
[ -f "$JEV_SRC" ] || fail "vendored client missing at $JEV_SRC"

# The client also looks for a zen.key beside itself, so run a copy from a
# directory that holds no key: a maintainer's local key must not leak into
# the no-key case or into any request.
JEV_DIR="$TMP_ROOT/client"
mkdir -p "$JEV_DIR"
cp "$JEV_SRC" "$JEV_DIR/jev.py"
JEV="$JEV_DIR/jev.py"

# Print a local TCP port that nothing listens on: bind an ephemeral port, then
# release it, so a connection attempt is refused immediately.
closed_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

test_missing_key_exits_2_and_names_the_key() {
  local home rc out err
  home="$TMP_ROOT/empty-home"
  mkdir -p "$home"
  rc=0
  printf '%s' "$REQUEST" | env -u ZEN_API_KEY HOME="$home" \
    JEV_ENDPOINT="http://127.0.0.1:9/unused" \
    timeout 20 python3 "$JEV" >"$TMP_ROOT/nokey.out" 2>"$TMP_ROOT/nokey.err" || rc=$?
  out=$(cat "$TMP_ROOT/nokey.out")
  err=$(cat "$TMP_ROOT/nokey.err")
  expect_code 2 "$rc" "missing key"
  assert_contains "$err" "ZEN_API_KEY" "missing-key stderr must name the env variable"
  assert_contains "$err" ".jev/zen.key" "missing-key stderr must name the key file"
  assert_not_contains "$err" "Traceback" "missing key must not crash with a traceback"
  [ -z "$out" ] || fail "missing key must print nothing on stdout, got: $out"
  pass "missing key exits 2 and names the key on stderr"
}

test_unreachable_endpoint_exits_1_with_json_error() {
  local home port rc out err start elapsed
  home="$TMP_ROOT/key-home"
  mkdir -p "$home"
  port=$(closed_port)
  start=$(date +%s)
  rc=0
  printf '%s' "$REQUEST" | HOME="$home" ZEN_API_KEY="offline-test-not-a-key" \
    JEV_ENDPOINT="http://127.0.0.1:$port/zen/v1/systemone" \
    timeout 30 python3 "$JEV" >"$TMP_ROOT/closed.out" 2>"$TMP_ROOT/closed.err" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  out=$(cat "$TMP_ROOT/closed.out")
  err=$(cat "$TMP_ROOT/closed.err")
  [ "$rc" != 124 ] || fail "client hung past the 30s bound against a closed port"
  expect_code 1 "$rc" "unreachable endpoint"
  assert_not_contains "$err" "Traceback" "unreachable endpoint must not crash with a traceback"
  assert_not_contains "$out" "Traceback" "unreachable endpoint must not print a traceback"
  printf '%s' "$out" | python3 -c 'import json, sys; o = json.load(sys.stdin); assert isinstance(o, dict) and o.get("error"), o' \
    || fail "unreachable endpoint must print a JSON object with an error field, got: $out"
  assert_contains "$out" "attempts" "unreachable endpoint error must report the exhausted retries"
  pass "unreachable endpoint exits 1 with a JSON error in ${elapsed}s"
}

test_missing_key_exits_2_and_names_the_key
test_unreachable_endpoint_exits_1_with_json_error
