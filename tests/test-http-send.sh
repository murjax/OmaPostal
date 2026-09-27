#!/usr/bin/env bash
# Tests for bin/http-send — sends a request described by a JSON file, prints
# one JSON result line.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$HERE/../bin/http-send"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
cleanup() {
  [[ -n ${server_pid:-} ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

req() { printf '%s' "$1" >"$tmp/req.json"; }

# ---- input validation (no network needed) ----------------------------------

out=$("$BIN" "$tmp/does-not-exist.json")
printf '%s' "$out" | jq -e '.ok == false and (.error | length > 0)' >/dev/null \
  && pass "missing request file -> ok:false with error" || fail "missing request file: $out"

printf 'not json' >"$tmp/bad.json"
out=$("$BIN" "$tmp/bad.json")
printf '%s' "$out" | jq -e '.ok == false' >/dev/null \
  && pass "invalid request JSON -> ok:false" || fail "invalid JSON: $out"

req '{"method":"GET"}'
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == false and (.error | length > 0)' >/dev/null \
  && pass "missing url -> ok:false with error" || fail "missing url: $out"

req '{"method":"GET","url":"ftp://example.com"}'
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == false' >/dev/null \
  && pass "non-http(s) scheme rejected" || fail "bad scheme: $out"

# ---- network failure ---------------------------------------------------------

req '{"method":"GET","url":"http://127.0.0.1:1","timeoutSec":3}'
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == false and (.error | length > 0) and .status == 0' >/dev/null \
  && pass "connection refused -> ok:false with curl's error" || fail "connection refused: $out"

# ---- happy path, against a local test server --------------------------------

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$HERE/fixtures/echo_server.py" "$port" &
server_pid=$!

for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/echo" && break
  sleep 0.1
done

req "{\"method\":\"POST\",\"url\":\"http://127.0.0.1:$port/echo\",\"headers\":{\"X-Custom\":\"abc123\"},\"body\":\"hello world\"}"
out=$("$BIN" "$tmp/req.json")

printf '%s' "$out" | jq -e '.ok == true and .status == 200' >/dev/null \
  && pass "successful POST -> ok:true, status 200" || fail "status: $out"

printf '%s' "$out" | jq -e '.headers["X-Test"] == "yes"' >/dev/null \
  && pass "response headers captured" || fail "headers: $out"

printf '%s' "$out" | jq -e '(.body | fromjson).method == "POST" and (.body | fromjson).body == "hello world"' >/dev/null \
  && pass "request method and body reached the server" || fail "echoed body: $out"

printf '%s' "$out" | jq -e '(.body | fromjson).headers["X-Custom"] == "abc123"' >/dev/null \
  && pass "custom request header reached the server" || fail "echoed header: $out"

printf '%s' "$out" | jq -e '.timeMs >= 0 and .sizeBytes > 0 and .truncated == false' >/dev/null \
  && pass "timing/size metadata present" || fail "metadata: $out"

req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/status/404\"}"
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == true and .status == 404' >/dev/null \
  && pass "4xx response is still ok:true (transport succeeded)" || fail "4xx: $out"

req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/redirect\"}"
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == true and .status == 200 and .headers["X-Test"] == "yes"' >/dev/null \
  && pass "redirect is followed to the final response" || fail "redirect: $out"

# ---- oversized/streamed response is capped at transfer time, not disk-checked after -----

req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/stream/20000000\"}"
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == true and .status == 200 and .truncated == true' >/dev/null \
  && pass "oversized streamed response -> ok:true, truncated:true" || fail "stream cap: $out"
printf '%s' "$out" | jq -e '.sizeBytes > 0 and .sizeBytes < 3000000' >/dev/null \
  && pass "curl aborts the transfer near the cap, not after downloading the full 20MB" \
  || fail "stream cap size: $out"

# ---- groups: defaults, environments, variables -------------------------------

G="$tmp/group.json"
cat >"$G" <<EOF
{
  "name": "T",
  "baseUrl": "{{host}}",
  "headers": { "Accept": "application/json", "X-Group": "g", "X-Both": "from-group", "X-Env": "{{tag}}" },
  "environments": {
    "dev": { "host": "http://127.0.0.1:$port", "tag": "alpha" },
    "alt": { "host": "http://127.0.0.1:$port", "tag": "beta" }
  },
  "activeEnv": "dev",
  "requests": [
    { "name": "Saved", "method": "POST", "path": "/echo", "body": "saved {{tag}}", "headers": { "X-Saved": "1" } }
  ]
}
EOF

gsend() { req "$1"; out=$("$BIN" "$tmp/req.json"); }
check() { printf '%s' "$out" | jq -e "$1" >/dev/null && pass "$2" || fail "$2: $out"; }

gsend "{\"groupFile\":\"$G\",\"path\":\"/echo\",\"headers\":{\"x-both\":\"from-request\"}}"
check '.ok == true and .status == 200' "group request succeeds"
check '(.body|fromjson).headers["X-Group"] == "g"' "group default header is sent"
check '(.body|fromjson).headers | to_entries | map(select(.key|ascii_downcase=="x-both") | .value) == ["from-request"]' \
  "request header overrides group header (case-insensitive, sent once)"
check '(.body|fromjson).headers["X-Env"] == "alpha"' "activeEnv variables are substituted"
check ".resolved.url == \"http://127.0.0.1:$port/echo\" and .resolved.method == \"GET\"" "resolved url/method reported"

gsend "{\"groupFile\":\"$G\",\"env\":\"alt\",\"path\":\"/echo\"}"
check '(.body|fromjson).headers["X-Env"] == "beta"' "env in request overrides activeEnv"

gsend "{\"groupFile\":\"$G\",\"requestName\":\"Saved\"}"
check '(.body|fromjson) | .method == "POST" and .body == "saved alpha" and .headers["X-Saved"] == "1"' \
  "saved request loaded by name, body variables substituted"
check '.resolved.body == "saved alpha"' "resolved output reports the substituted body"

gsend "{\"groupFile\":\"$G\",\"requestName\":\"Saved\",\"body\":\"override\"}"
check '(.body|fromjson).body == "override"' "request-file fields overlay the saved request"

gsend "{\"groupFile\":\"$G\",\"path\":\"http://127.0.0.1:$port/echo\"}"
check ".ok == true and .resolved.url == \"http://127.0.0.1:$port/echo\"" "absolute url skips baseUrl"

jq '.baseUrl = "http://127.0.0.1:'"$port"'/"' "$G" >"$tmp/slash.json"
gsend "{\"groupFile\":\"$tmp/slash.json\",\"path\":\"echo\"}"
check ".ok == true and .resolved.url == \"http://127.0.0.1:$port/echo\"" "baseUrl trailing slash and bare path join with one slash"

gsend "{\"groupFile\":\"$G\",\"path\":\"/{{nope}}\"}"
check '.ok == false and (.error | contains("undefined variable: nope"))' "undefined variable is an error naming it"

gsend "{\"groupFile\":\"$G\",\"env\":\"staging\",\"path\":\"/echo\"}"
check '.ok == false and (.error | contains("unknown environment: staging"))' "unknown environment is an error"

gsend "{\"groupFile\":\"$G\",\"requestName\":\"Nope\"}"
check '.ok == false and (.error | contains("unknown request: Nope"))' "unknown saved request is an error"

gsend "{\"groupFile\":\"$tmp/missing-group.json\",\"path\":\"/echo\"}"
check '.ok == false and (.error | contains("group file not found"))' "missing group file is an error"

printf 'not json' >"$tmp/badgroup.json"
gsend "{\"groupFile\":\"$tmp/badgroup.json\",\"path\":\"/echo\"}"
check '.ok == false and (.error | contains("invalid group file"))' "invalid group file is an error"

# ---- groups: auth --------------------------------------------------------------

# Group with default auth $1 (JSON), request body $2 (extra request-file fields).
authsend() {
  jq --argjson a "$1" '.auth = $a' "$G" >"$tmp/ga.json"
  req "$(jq -nc --arg g "$tmp/ga.json" --argjson extra "${2:-{\}}" '{groupFile:$g, path:"/echo"} + $extra')"
  out=$("$BIN" "$tmp/req.json")
}

authsend '{"type":"bearer","token":"{{tag}}"}'
check '(.body|fromjson).headers["Authorization"] == "Bearer alpha"' "group bearer auth inherited by default"

authsend '{"type":"bearer","token":"t"}' '{"auth":"none"}'
check '(.body|fromjson).headers | has("Authorization") | not' "request auth none suppresses group auth"

authsend '{"type":"bearer","token":"t"}' '{"auth":{"type":"basic","username":"u","password":"p"}}'
check '(.body|fromjson).headers["Authorization"] == "Basic dTpw"' "request auth block overrides group auth (basic)"

authsend '{"type":"apiKey","name":"X-Api-Key","value":"{{tag}}","in":"header"}'
check '(.body|fromjson).headers["X-Api-Key"] == "alpha"' "apiKey in header"

authsend '{"type":"apiKey","name":"key","value":"{{tag}}","in":"query"}'
check '(.body|fromjson).path == "/echo?key=alpha"' "apiKey in query string"

authsend '{"type":"apiKey","name":"key","value":"a b","in":"query"}' '{"path":"/echo?x=1"}'
check '(.body|fromjson).path == "/echo?x=1&key=a%20b"' "apiKey query is URL-encoded and joins with &"

authsend '{"type":"bearer","token":"t"}' '{"headers":{"authorization":"manual"}}'
check '(.body|fromjson).headers | to_entries | map(select(.key|ascii_downcase=="authorization") | .value) == ["Bearer t"]' \
  "auth overwrites an explicit Authorization header"

authsend '{"type":"bearer","token":"secret-token"}'
check '.resolved.headers.Authorization == "••••" and ((.resolved | tojson) | contains("secret-token") | not)' \
  "resolved output masks bearer token"

authsend '{"type":"apiKey","name":"key","value":"secret-key","in":"query"}'
check ".resolved.url == \"http://127.0.0.1:$port/echo?key=••••\"" "resolved output masks query apiKey"

authsend '{"type":"kerberos"}'
check '.ok == false and (.error | contains("unknown auth type: kerberos"))' "unknown auth type is an error"

# A group file whose auth is the bare string "none" (older GroupEditor saves) must not break sends.
authsend '"none"'
check '.ok == true and .status == 200 and ((.body|fromjson).headers | has("Authorization") | not)' "group auth saved as string \"none\" is treated as none"

# ---- cancellation: TERM stops http-send and its curl child -------------------

req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/sleep/20\",\"timeoutSec\":30}"
"$BIN" "$tmp/req.json" >"$tmp/term.out" 2>&1 &
sendpid=$!
sleep 0.5
kill -TERM "$sendpid"
for _ in $(seq 1 20); do kill -0 "$sendpid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$sendpid" 2>/dev/null; then
  fail "http-send exits promptly on TERM"
  kill -KILL "$sendpid" 2>/dev/null
else
  pass "http-send exits promptly on TERM"
fi
sleep 0.3
if pgrep -f "127.0.0.1:$port/sleep/20" >/dev/null; then
  fail "curl child is killed on TERM"
  pkill -f "127.0.0.1:$port/sleep/20"
else
  pass "curl child is killed on TERM"
fi

# ---- headers/body reach curl without exposing secrets on the process list ----

secret="s3cr3t-token-$$-$RANDOM"
req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/sleep/2\",\"headers\":{\"Authorization\":\"Bearer $secret\"},\"timeoutSec\":10}"
"$BIN" "$tmp/req.json" >"$tmp/argv.out" &
argvpid=$!
sleep 0.5
# Only curl's own argv matters here; the surrounding test harness may echo
# this script's source (secret literal included) into its own process line.
curlpid=$(pgrep -f "curl.*127\.0\.0\.1:$port/sleep/2" | head -1)
if [[ -n $curlpid ]] && tr '\0' '\n' <"/proc/$curlpid/cmdline" 2>/dev/null | grep -F -- "$secret" >/dev/null; then
  fail "curl argv does not expose the Authorization header"
else
  pass "curl argv does not expose the Authorization header"
fi
wait "$argvpid"
printf '%s' "$(<"$tmp/argv.out")" | jq -e '.ok == true and .status == 200' >/dev/null \
  && pass "request with hidden-argv header still succeeds" || fail "hidden-argv request: $(<"$tmp/argv.out")"

# ---- group-mode secrets are not exposed to jq's own argv either --------------
# Same vulnerability class as the curl check above, but for the `jq -f
# resolve.jq` step that resolves group-mode requests into a concrete one.
# That jq process typically exits in milliseconds, too fast to reliably win a
# race against /proc/<pid>/cmdline scraping, so this uses `bash -x` instead:
# it prints every command's fully-expanded argv as it's about to run, giving
# a precise, non-racy record of exactly what each jq invocation received.
secretG="s3cr3t-group-$$-$RANDOM"
groupSecretFile="$tmp/group-secret.json"
cat >"$groupSecretFile" <<EOF
{"name":"S","baseUrl":"http://127.0.0.1:$port","auth":{"type":"bearer","token":"$secretG"}}
EOF
req "{\"groupFile\":\"$groupSecretFile\",\"path\":\"/echo\"}"
bash -x "$BIN" "$tmp/req.json" >"$tmp/xtrace.out" 2>"$tmp/xtrace.err"
if grep -E '^[+]+ jq ' "$tmp/xtrace.err" | grep -F -- "$secretG" >/dev/null; then
  fail "group-mode jq invocation does not expose the auth token via argv"
else
  pass "group-mode jq invocation does not expose the auth token via argv"
fi
printf '%s' "$(<"$tmp/xtrace.out")" | jq -e '.ok == true and .status == 200' >/dev/null \
  && pass "group request with hidden-argv secret still succeeds" || fail "hidden-argv group request: $(<"$tmp/xtrace.out")"

# ---- an apiKey-in-query auth value is not exposed via curl's argv either ----
# lib/resolve.jq's apiKey/query auth appends the key as part of the resolved
# URL, and that URL used to be appended straight to curl_args — visible via
# `ps`/`/proc/<pid>/cmdline` just like the header/body case above.
secretQ="s3cr3t-query-$$-$RANDOM"
groupQueryFile="$tmp/group-query-secret.json"
cat >"$groupQueryFile" <<EOF
{"name":"Q","baseUrl":"http://127.0.0.1:$port","auth":{"type":"apiKey","name":"key","value":"$secretQ","in":"query"}}
EOF
req "{\"groupFile\":\"$groupQueryFile\",\"path\":\"/sleep/2\"}"
"$BIN" "$tmp/req.json" >"$tmp/queryargv.out" &
queryargvpid=$!
sleep 0.5
curlpid=$(pgrep -f "curl.*127\.0\.0\.1:$port/sleep/2" | head -1)
if [[ -n $curlpid ]] && tr '\0' '\n' <"/proc/$curlpid/cmdline" 2>/dev/null | grep -F -- "$secretQ" >/dev/null; then
  fail "curl argv does not expose an apiKey-in-query auth value"
else
  pass "curl argv does not expose an apiKey-in-query auth value"
fi
wait "$queryargvpid"
printf '%s' "$(<"$tmp/queryargv.out")" | jq -e '.ok == true and .status == 200' >/dev/null \
  && pass "request with hidden-argv query secret still succeeds" || fail "hidden-argv query request: $(<"$tmp/queryargv.out")"

# ---- resolved (unmasked body / unauthenticated headers) is not exposed to --
# ---- the final output-building jq's own argv either -------------------------
# .resolved always carries the real, unmasked request body (and, for an
# unauthenticated group, unmasked headers too — only auth-derived values get
# masked), so it must not sit on that jq process's argv even though it's
# meant to reach the UI/history file.
secretBody="s3cr3t-resolved-body-$$-$RANDOM"
secretHeader="s3cr3t-resolved-header-$$-$RANDOM"
groupUnauthFile="$tmp/group-unauth.json"
cat >"$groupUnauthFile" <<EOF
{"name":"U","baseUrl":"http://127.0.0.1:$port","auth":{"type":"none"}}
EOF
req "{\"groupFile\":\"$groupUnauthFile\",\"path\":\"/echo\",\"body\":\"$secretBody\",\"headers\":{\"X-Plain\":\"$secretHeader\"}}"
bash -x "$BIN" "$tmp/req.json" >"$tmp/resolved-xtrace.out" 2>"$tmp/resolved-xtrace.err"
if grep -E '^[+]+ jq ' "$tmp/resolved-xtrace.err" | grep -F -e "$secretBody" -e "$secretHeader" >/dev/null; then
  fail "final output jq invocation does not expose unmasked resolved data via argv"
else
  pass "final output jq invocation does not expose unmasked resolved data via argv"
fi
printf '%s' "$(<"$tmp/resolved-xtrace.out")" | jq -e \
  '.ok == true and .resolved.body == "'"$secretBody"'" and .resolved.headers["X-Plain"] == "'"$secretHeader"'"' >/dev/null \
  && pass "resolved output still carries the unmasked body/header for the UI" \
  || fail "hidden-argv resolved request: $(<"$tmp/resolved-xtrace.out")"

# A backslash in a header value or body must reach the server unchanged, not
# doubled — regression test for jq's @tsv escaping a lone backslash to `\\`.
req '{"method":"POST","url":"http://127.0.0.1:'"$port"'/echo","headers":{"X-Custom":"a\\b\"c"},"body":"one\\two"}'
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '(.body | fromjson).headers["X-Custom"] == "a\\b\"c" and (.body | fromjson).body == "one\\two"' >/dev/null \
  && pass "header/body backslash reaches the server unescaped-once" || fail "backslash: $out"

# ---- the panel adds a changing "nonce" field; it must be ignored ---------------

req "{\"method\":\"GET\",\"url\":\"http://127.0.0.1:$port/echo\",\"nonce\":\"123-abc\"}"
out=$("$BIN" "$tmp/req.json")
printf '%s' "$out" | jq -e '.ok == true and .status == 200' >/dev/null \
  && pass "ad-hoc request ignores the nonce field" || fail "nonce (ad-hoc): $out"

gsend "{\"groupFile\":\"$G\",\"path\":\"/echo\",\"nonce\":\"123-abc\"}"
check '.ok == true and .status == 200' "group request ignores the nonce field"

exit $((fails > 0 ? 1 : 0))
