#!/usr/bin/env bash
# tests/fm-test-lib.test.sh - behavior tests for the shared test primitives in
# tests/lib.sh that every other fixture depends on being correct. A defect here
# is invisible from the outside: it does not fail the helper, it quietly changes
# what the fixtures built on it actually exercise. Covers
# fm_test_system_path_without, whose job is to present a host WITHOUT a named
# tool while resolving everything else exactly as the effective base path does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-lib)

HIGH="$TMP_ROOT/high"
LOW="$TMP_ROOT/low"
mkdir -p "$HIGH" "$LOW"
for tier in HIGH LOW; do
  dir=${!tier}
  # An absolute interpreter, because these stubs run under a PATH that is only
  # the mirror and therefore cannot resolve `env`.
  cat > "$dir/fmtool" <<SH
#!/bin/sh
printf '%s\n' $tier
SH
  chmod +x "$dir/fmtool"
  printf '#!/bin/sh\nexit 0\n' > "$dir/fmtool-withheld"
  chmod +x "$dir/fmtool-withheld"
done
cat > "$LOW/fmtool-low-only" <<'SH'
#!/bin/sh
printf '%s\n' LOW-ONLY
SH
chmod +x "$LOW/fmtool-low-only"

# --- fm_test_system_path_without: base path precedence -----------------------

# PATH resolves left to right, so a name carried by two directories of the
# effective base path must come from the earlier one. An operator who puts a
# newer toolchain ahead of /usr/bin (a Nix store git before the distro git) gets
# that version in every fixture that reads FM_TEST_BASE_PATH directly, and the
# mirror has to agree with them: otherwise the override is silently defeated for
# exactly the fixtures built on this helper, and nothing reports the swap.
mirror=$(FM_TEST_BASE_PATH="$HIGH:$LOW" \
  fm_test_system_path_without "$TMP_ROOT/mirror-high-first" fmtool-withheld) \
  || fail "fm_test_system_path_without failed with a two-directory base path"
got=$(PATH="$mirror" fmtool)
[ "$got" = HIGH ] \
  || fail "the mirror resolved a shared name to '$got', not to the earlier base path directory"
pass "fm_test_system_path_without resolves a shared name to the earlier base path directory"

# The same two directories in the opposite order must flip the answer. Without
# this the case above would also pass on a mirror that always won from one side,
# so the pair is what pins precedence to the base path's own order.
reversed=$(FM_TEST_BASE_PATH="$LOW:$HIGH" \
  fm_test_system_path_without "$TMP_ROOT/mirror-low-first" fmtool-withheld) \
  || fail "fm_test_system_path_without failed with the reversed base path"
got=$(PATH="$reversed" fmtool)
[ "$got" = LOW ] \
  || fail "reversing the base path did not reverse which directory won the shared name"
pass "the winning directory follows the base path order rather than a fixed side"

# --- fm_test_system_path_without: the absence it exists to guarantee ---------

# The withheld tool sits in BOTH source directories, so a mirror that dropped
# only one copy would still resolve it and hand the fixture a vacuous pass.
! PATH="$mirror" command -v fmtool-withheld >/dev/null 2>&1 \
  || fail "a withheld tool still resolves on the mirrored PATH"
pass "a named tool stays absent even when every base path directory carries it"

# Everything the base path offers and the caller did not withhold must survive,
# including a name carried by the lower-priority directory alone.
got=$(PATH="$mirror" fmtool-low-only)
[ "$got" = LOW-ONLY ] \
  || fail "the mirror dropped a name carried only by the lower-priority directory"
pass "the mirror keeps every name the base path offers that was not withheld"

# --- fm_test_system_path_without: entry shapes -------------------------------

# An empty source directory expands to a literal glob rather than to nothing, so
# a mirror that linked it blindly would grow an entry named '*'. A missing
# directory and a blank base path field are equally non-fatal.
mkdir -p "$TMP_ROOT/empty"
sparse=$(FM_TEST_BASE_PATH="$TMP_ROOT/empty::$TMP_ROOT/does-not-exist:$HIGH" \
  fm_test_system_path_without "$TMP_ROOT/mirror-sparse" fmtool-withheld) \
  || fail "fm_test_system_path_without failed on an empty, missing, or blank base path entry"
assert_absent "$sparse/*" "the mirror linked an unmatched glob as a literal entry"
got=$(PATH="$sparse" fmtool)
[ "$got" = HIGH ] \
  || fail "a sparse base path lost the directory that does carry the tool"
pass "empty, missing, and blank base path entries are skipped without breaking the mirror"

# A dangling symlink is a real PATH entry: a fixture may be about what happens
# when a tool resolves to a broken link, so the mirror carries it rather than
# silently pruning it.
ln -s "$TMP_ROOT/nowhere" "$HIGH/fmtool-dangling"
dangling=$(FM_TEST_BASE_PATH="$HIGH" \
  fm_test_system_path_without "$TMP_ROOT/mirror-dangling" fmtool-withheld) \
  || fail "fm_test_system_path_without failed on a directory holding a dangling symlink"
[ -L "$dangling/fmtool-dangling" ] \
  || fail "the mirror dropped a dangling symlink instead of carrying it as a real entry"
pass "a dangling symlink is mirrored as the real entry it is"

# --- fm_test_system_path_without: the default base path ----------------------

# With no override the helper must still mirror the documented default, which is
# the same string its call sites default to. Comparing the two mirrors pins that
# without assuming any particular host layout, since the host that needs the
# override is exactly the host where naming a tool here would prove nothing.
default_mirror=$(unset FM_TEST_BASE_PATH
  fm_test_system_path_without "$TMP_ROOT/mirror-default" env) \
  || fail "fm_test_system_path_without failed with no base path override"
explicit_mirror=$(FM_TEST_BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  fm_test_system_path_without "$TMP_ROOT/mirror-default-explicit" env) \
  || fail "fm_test_system_path_without failed with the default base path spelled out"
ls -A "$default_mirror" | LC_ALL=C sort > "$TMP_ROOT/default.list"
ls -A "$explicit_mirror" | LC_ALL=C sort > "$TMP_ROOT/explicit.list"
[ -s "$TMP_ROOT/default.list" ] || fail "the default mirror is empty"
cmp -s "$TMP_ROOT/default.list" "$TMP_ROOT/explicit.list" \
  || fail "no override does not mirror the same directories as the documented default base path"
! PATH="$default_mirror" command -v env >/dev/null 2>&1 \
  || fail "the withheld tool still resolves on the default mirrored PATH"
pass "the default base path mirrors the documented system directories without the named tools"

echo "# fm-test-lib.test.sh: all assertions passed"
