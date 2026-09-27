#!/usr/bin/env bash
# Tests for bin/http-curl — formats a JSON request file (same shape http-send
# accepts) as a copy-pasteable curl command line; never sends anything.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$HERE/../bin/http-curl"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

req() { printf '%s' "$1" >"$tmp/req.json"; }
send() { req "$1"; out=$("$BIN" "$tmp/req.json"); }
check() { printf '%s' "$out" | jq -e "$1" >/dev/null && pass "$2" || fail "$2: $out"; }

# ---- input validation ------------------------------------------------------

out=$("$BIN" "$tmp/does-not-exist.json")
printf '%s' "$out" | jq -e '.ok == false and (.error | length > 0)' >/dev/null \
  && pass "missing request file -> ok:false with error" || fail "missing request file: $out"

printf 'not json' >"$tmp/bad.json"
out=$("$BIN" "$tmp/bad.json")
printf '%s' "$out" | jq -e '.ok == false' >/dev/null \
  && pass "invalid request JSON -> ok:false" || fail "invalid JSON: $out"

send '{"method":"GET"}'
check '.ok == false and (.error | length > 0)' "missing url -> ok:false with error"

# ---- ad-hoc requests --------------------------------------------------------

send '{"method":"POST","url":"https://api.example.com/things?x=1","headers":{"Content-Type":"application/json"},"body":"{\"a\":1}","timeoutSec":15}'
check ".ok == true and (.curl | startswith(\"'curl'\"))" "ad-hoc request produces a curl command"
check "(.curl | contains(\"'-X' 'POST'\"))" "method is included"
check '.curl | contains("https://api.example.com/things?x=1")' "url is included, unquoted content intact"
check '.curl | contains("Content-Type: application/json")' "header is included"
check '.curl | contains("--data-binary")' "body flag is included"
check "(.curl | contains(\"'--max-time' '15'\"))" "custom timeout is reflected"

send '{"method":"GET","url":"https://api.example.com/x","body":""}'
check '(.curl | contains("--data-binary")) | not' "empty body omits --data-binary"

send "{\"method\":\"GET\",\"url\":\"https://api.example.com\",\"body\":\"it's a test\"}"
check ".curl | contains(\"it'\\\\''s a test\")" "single quotes in body are shell-escaped"

# ---- group mode: baseUrl, {{vars}} and auth are resolved and unmasked ------

G="$tmp/group.json"
cat >"$G" <<'EOF'
{
  "name": "T",
  "baseUrl": "https://{{host}}/api",
  "auth": { "type": "bearer", "token": "{{token}}" },
  "headers": { "X-Default": "1" },
  "environments": { "dev": { "host": "dev.example.com", "token": "secret123" } },
  "activeEnv": "dev",
  "requests": [
    { "name": "Saved", "method": "POST", "path": "/widgets", "body": "hi {{token}}" }
  ]
}
EOF

send "{\"groupFile\":\"$G\",\"path\":\"/widgets?x=1\",\"auth\":\"inherit\"}"
check '.ok == true' "group request resolves"
check '.curl | contains("https://dev.example.com/api/widgets?x=1")' "baseUrl + path joined and {{vars}} substituted"
check '.curl | contains("Authorization: Bearer secret123")' "auth token is unmasked (meant to actually run)"
check '.curl | contains("X-Default: 1")' "group default header is included"

send "{\"groupFile\":\"$G\",\"requestName\":\"Saved\"}"
check '.ok == true and (.curl | contains("hi secret123"))' "saved request body variables substituted"

send "{\"groupFile\":\"$G\",\"path\":\"/x\",\"auth\":\"none\"}"
check '(.curl | contains("Authorization")) | not' "auth none suppresses the header"

send "{\"groupFile\":\"$tmp/does-not-exist.json\",\"path\":\"/x\"}"
check '.ok == false and (.error | contains("group file not found"))' "missing group file is an error"

send "{\"groupFile\":\"$G\",\"path\":\"/{{nope}}\"}"
check '.ok == false and (.error | contains("undefined variable: nope"))' "undefined variable is an error naming it"

# ---- group-mode secrets are not exposed to jq's own argv --------------------
# `bin/http-curl` never runs curl itself, but it does run `jq -f resolve.jq`
# to resolve group mode, and that step must not put the group's auth token on
# its own argv (readable by other local users via `ps`/`/proc/<pid>/cmdline`
# for as long as it runs) even though the final printed command is meant to
# carry it unmasked. `bash -x` prints each command's fully-expanded argv as
# it's about to run, giving a precise, non-racy record — unlike scraping
# /proc/<pid>/cmdline, which would need to win a timing race against a jq
# process that usually exits in milliseconds.
req "{\"groupFile\":\"$G\",\"path\":\"/widgets\"}"
bash -x "$BIN" "$tmp/req.json" >"$tmp/xtrace.out" 2>"$tmp/xtrace.err"
if grep -E '^[+]+ jq ' "$tmp/xtrace.err" | grep -F -- "secret123" >/dev/null; then
  fail "group-mode jq invocation does not expose the auth token via argv"
else
  pass "group-mode jq invocation does not expose the auth token via argv"
fi
out=$(<"$tmp/xtrace.out")
check '.ok == true and (.curl | contains("Authorization: Bearer secret123"))' \
  "group command with hidden-argv secret still prints the token"

exit $((fails > 0))
