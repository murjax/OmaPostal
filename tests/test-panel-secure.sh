#!/usr/bin/env bash
# The panel writes its request payload and its history through Quickshell's
# FileView, which has no file-mode option: it creates a missing parent
# directory 0755 and a new file 0644. bin/http-secure makes them 0700/0600
# first, but it is a process, so a send() issued in the same event loop turn as
# the panel opening could beat it and put the request's Authorization header on
# disk world-readable. lib/secure.js is the gate that holds those writes back.
#
# These tests run that race for real, through tests/fixtures/secure-harness.qml
# (the same gate, the same http-secure call, the same ordering as Panel.qml).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HARNESS="$HERE/fixtures/secure-harness.qml"
SECRET="s3cr3t-harness-token"

command -v qs >/dev/null 2>&1 || { echo "skip - quickshell (qs) not installed"; exit 0; }
[[ -n ${XDG_RUNTIME_DIR:-} ]] || { echo "skip - quickshell needs XDG_RUNTIME_DIR"; exit 0; }

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; rc=1; }
rc=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A bin/ whose http-secure always fails, to exercise the refusal path.
mkdir -p "$TMP/failbin"
cat >"$TMP/failbin/http-secure" <<'STUB'
#!/usr/bin/env bash
jq -nc '{ok:false,dir:"",files:[],error:"cannot chmod 700 (simulated)"}'
exit 1
STUB
chmod 755 "$TMP/failbin/http-secure"

# The harness imports lib/secure.js, and quickshell refuses an import that
# escapes the shell root. Stage the real file next to it rather than keeping a
# copy in the tree, so these tests always run against the shipped gate.
mkdir -p "$TMP/harness"
cp "$HERE/fixtures/secure-harness.qml" "$HERE/../lib/secure.js" "$TMP/harness/"

# run <mode> <bin> [prep] -> sets RUN_OUTCOME, RUN_DIRMODE, RUN_FILEMODE, RUN_DIR.
# `prep` is evaluated with RUN_DIR already set, to seed the directory before
# the panel starts. Not a subshell, so the caller can also inspect what was
# written.
RUN_OUTCOME="" RUN_DIRMODE="" RUN_FILEMODE="" RUN_DIR=""
run() {
  local mode=$1 bin=$2 prep=${3:-} result
  RUN_DIR=$TMP/run-$((++n))/private
  result=$TMP/result-$n
  [[ -n $prep ]] && eval "$prep"
  # 022, the umask that makes FileView's 0644 world-readable in the first place.
  ( umask 022
    HARNESS_DIR="$RUN_DIR" HARNESS_BIN="$bin" HARNESS_MODE="$mode" \
    HARNESS_RESULT="$result" HARNESS_SECRET="$SECRET" \
    QT_QPA_PLATFORM=offscreen timeout 60 qs -p "$TMP/harness/secure-harness.qml" >/dev/null 2>&1 )
  RUN_OUTCOME=$(sed -n 1p "$result" 2>/dev/null)
  RUN_OUTCOME=${RUN_OUTCOME:-NORESULT}
  RUN_DIRMODE=$(stat -c '%a' "$RUN_DIR" 2>/dev/null || echo -)
  RUN_FILEMODE=$(stat -c '%a' "$RUN_DIR/request.json" 2>/dev/null || echo -)
  RUN_GOT="$RUN_OUTCOME|$RUN_DIRMODE|$RUN_FILEMODE"
}
n=0

# ---- without the gate, the credential lands world-readable -----------------
# The control: this is what Panel.qml did before the gate, and it is why the
# gate is not cosmetic. If FileView ever gains a file-mode option this test is
# the one that should start failing.
run ungated "$HERE/../bin"
[[ $RUN_GOT == "WROTE|755|644" ]] \
  && pass "control: an ungated FileView write creates the dir 0755 and the file 0644" \
  || fail "control: expected WROTE|755|644, got $RUN_GOT"
grep -q "$SECRET" "$RUN_DIR/request.json" 2>/dev/null \
  && pass "control: the credential really is in that world-readable file" \
  || fail "control: harness did not write the credential"

# ---- with the gate, the write waits for http-secure ------------------------
run gated "$HERE/../bin"
[[ $RUN_GOT == "WROTE|700|600" ]] \
  && pass "a send racing http-secure is deferred; dir is 0700 and file 0600 when it lands" \
  || fail "gated: expected WROTE|700|600, got $RUN_GOT"
grep -q "$SECRET" "$RUN_DIR/request.json" 2>/dev/null \
  && pass "the deferred send is not dropped — the payload still reaches the file" \
  || fail "gated: deferred send lost the payload"

# ---- if securing fails, nothing is written at all --------------------------
run gated "$TMP/failbin"
[[ $RUN_GOT == "REFUSED|-|-" ]] \
  && pass "http-secure failing refuses the send instead of writing it unprotected" \
  || fail "failing: expected REFUSED|-|-, got $RUN_GOT"

# ---- and that refusal is what a symlinked scratch path gets -----------------
# bin/http-secure refuses to follow a symlink at a path it owns; this is the
# other half of that, end to end. FileView follows a symlink like any other
# write, so the refusal has to reach the panel and stop the send, or the
# request payload lands wherever the link points.
run gated "$HERE/../bin" '
  mkdir -p "$RUN_DIR"
  ln -s "$TMP/never-created.json" "$RUN_DIR/request.json"
'
[[ $RUN_OUTCOME == "REFUSED" ]] \
  && pass "a symlinked scratch path refuses the send rather than writing through it" \
  || fail "symlink: expected REFUSED, got $RUN_OUTCOME"
[[ ! -e $TMP/never-created.json ]] \
  && pass "the symlink's target is never created, by http-secure or by FileView" \
  || fail "symlink: $TMP/never-created.json was created"

exit $rc
