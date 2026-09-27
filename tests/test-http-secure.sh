#!/usr/bin/env bash
# Tests for bin/http-secure — creates/repairs the private dir and files the
# panel writes through FileView, which has no file-mode option of its own.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$HERE/../bin/http-secure"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Everything below runs under a permissive umask on purpose: that is the case
# that made the history file world-readable in the first place.
umask 022

# ---- creating from nothing ---------------------------------------------------

scratch="$tmp/run/murjax.omapostal"
state="$tmp/state"
mkdir -p "$state"          # shared with other Omarchy modules; 0755 by default
hist="$state/history.json"

out=$("$BIN" init "$scratch" "$scratch/request.json" "$scratch/curl-request.json" "$hist")
printf '%s' "$out" | jq -e --arg d "$scratch" '.ok == true and .dir == $d and (.files | length) == 3' >/dev/null \
  && pass "init reports the dir and files it secured" || fail "init output: $out"

[[ $(stat -c '%a' "$scratch") == "700" ]] \
  && pass "the private dir is created 700 regardless of umask" || fail "dir mode: $(stat -c '%a' "$scratch")"

for f in "$scratch/request.json" "$scratch/curl-request.json" "$hist"; do
  mode=$(stat -c '%a' "$f" 2>/dev/null)
  [[ $mode == "600" ]] && pass "$(basename "$f") is created 600 regardless of umask" \
    || fail "$(basename "$f") mode: $mode"
done

# The history file's own directory is shared with other Omarchy modules, so
# narrowing it to 0700 would be overreach.
[[ $(stat -c '%a' "$state") == "755" ]] \
  && pass "a file's parent directory is left alone" || fail "shared parent mode: $(stat -c '%a' "$state")"

# ---- repairing what an earlier version already wrote -------------------------
# This is the case that matters in the field: the file already exists, 0644,
# with request headers and bodies in it.

chmod 755 "$scratch"
chmod 644 "$hist"
printf '[{"id":"keep-me"}]\n' >"$hist"
out=$("$BIN" init "$scratch" "$hist")
printf '%s' "$out" | jq -e '.ok == true' >/dev/null && pass "init succeeds on an existing dir/file" || fail "repair: $out"
[[ $(stat -c '%a' "$scratch") == "700" ]] \
  && pass "an existing 755 private dir is repaired to 700" || fail "repaired dir mode: $(stat -c '%a' "$scratch")"
[[ $(stat -c '%a' "$hist") == "600" ]] \
  && pass "an existing 644 file is repaired to 600" || fail "repaired file mode: $(stat -c '%a' "$hist")"
jq -e '.[0].id == "keep-me"' "$hist" >/dev/null \
  && pass "repairing a file does not touch its contents" || fail "contents: $(cat "$hist")"

# Idempotent: it runs on every panel open.
"$BIN" init "$scratch" "$hist" >/dev/null
[[ $(stat -c '%a' "$hist") == "600" ]] && jq -e '.[0].id == "keep-me"' "$hist" >/dev/null \
  && pass "running twice changes nothing" || fail "second run: $(stat -c '%a' "$hist") $(cat "$hist")"

# ---- a dir with no files is fine, and usage errors report JSON --------------

"$BIN" init "$tmp/bare" >/dev/null
[[ $(stat -c '%a' "$tmp/bare") == "700" ]] \
  && pass "init with no file arguments still creates the dir 700" || fail "bare dir mode: $(stat -c '%a' "$tmp/bare")"

"$BIN" >"$tmp/o.json" 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && jq -e '.ok == false and (.error | length > 0)' "$tmp/o.json" >/dev/null \
  && pass "no arguments -> error JSON and non-zero exit" || fail "no args (rc=$rc): $(cat "$tmp/o.json")"

"$BIN" init >"$tmp/o.json" 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && jq -e '.ok == false and (.error | length > 0)' "$tmp/o.json" >/dev/null \
  && pass "init with no dir -> error JSON and non-zero exit" || fail "init no dir (rc=$rc): $(cat "$tmp/o.json")"

"$BIN" bogus "$tmp/x" >"$tmp/o.json" 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && jq -e '.ok == false' "$tmp/o.json" >/dev/null \
  && pass "unknown subcommand -> error JSON and non-zero exit" || fail "bogus (rc=$rc): $(cat "$tmp/o.json")"

# ---- a file is never briefly world-readable on the way to 0600 --------------
# The create happens inside a `umask 077` subshell rather than as a plain
# redirection followed by chmod, so there is no window where it is 0644.
grep -q 'umask 077' "$BIN" \
  && pass "the file is created under umask 077, not chmodded after the fact" \
  || fail "http-secure no longer creates files under a restrictive umask"

exit $((fails > 0 ? 1 : 0))
