#!/usr/bin/env bash
# Tests for bin/http-groups — list/create group files.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$HERE/../bin/http-groups"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export OMARCHY_HTTP_GROUPS_DIR="$tmp/groups"

out=$("$BIN" list)
[[ $out == "[]" ]] && pass "list on a missing dir -> []" || fail "empty list: $out"

out=$("$BIN" new "My API!")
printf '%s' "$out" | jq -e --arg d "$tmp/groups" '.slug == "my-api" and .name == "My API!" and .path == ($d + "/my-api.json")' >/dev/null \
  && pass "new slugifies the name and reports the path" || fail "new: $out"

jq -e '.name == "My API!" and .requests == [] and .environments == {} and .auth.type == "none" and .headers == {}' \
  "$tmp/groups/my-api.json" >/dev/null && pass "new writes the skeleton" || fail "skeleton: $(cat "$tmp/groups/my-api.json")"

out=$("$BIN" new "My API")
printf '%s' "$out" | jq -e '.slug == "my-api-2"' >/dev/null \
  && pass "colliding slug gets a numeric suffix" || fail "collision: $out"

out=$("$BIN" new "!!!")
printf '%s' "$out" | jq -e '.slug == "group"' >/dev/null \
  && pass "name with no alphanumerics falls back to 'group'" || fail "fallback slug: $out"

printf 'not json' >"$tmp/groups/broken.json"
out=$("$BIN" list)
printf '%s' "$out" | jq -e 'length == 3 and (map(.slug) | index("broken") | not)' >/dev/null \
  && pass "list skips unparseable files" || fail "list: $out"

"$BIN" new "" >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "empty name -> error JSON and non-zero exit" || fail "empty name (rc=$rc): $(cat "$tmp/o.json")"

# ------------------------------------------------------------- postman import
FIXTURE="$HERE/fixtures/JSONPlaceholder.postman_collection.json"

out=$("$BIN" import "$FIXTURE")
printf '%s' "$out" | jq -e '.slug == "jsonplaceholder-api" and .name == "JSONPlaceholder API"
  and .requestCount == 42 and .warnings == []' >/dev/null \
  && pass "import converts a Postman collection into a new group" || fail "import: $out"

path=$(jq -r '.path' <<<"$out")
jq -e '(.requests | length) == 42
  and (.requests[0].name == "Posts / Get All Posts")
  and (.requests[0].path == "{{baseUrl}}/posts")
  and (.environments.default.baseUrl == "https://jsonplaceholder.typicode.com")
  and (.activeEnv == "default")
  and (.baseUrl == "")' "$path" >/dev/null \
  && pass "import flattens folders and captures collection variables as an env" \
  || fail "import group contents: $(cat "$path")"

out=$("$BIN" import "$FIXTURE" "Custom Name")
printf '%s' "$out" | jq -e '.slug == "custom-name" and .name == "Custom Name"' >/dev/null \
  && pass "import accepts an override name" || fail "import override name: $out"

"$BIN" import "$tmp/does-not-exist.json" >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "import: missing file -> error JSON and non-zero exit" || fail "import missing file (rc=$rc): $(cat "$tmp/o.json")"

echo '{"not":"a collection"}' >"$tmp/bad.json"
"$BIN" import "$tmp/bad.json" >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "import: not a Postman collection -> error JSON and non-zero exit" || fail "import bad file (rc=$rc): $(cat "$tmp/o.json")"

cat >"$tmp/unsupported.json" <<'JSON'
{
  "info": {"name": "Unsupported bits"},
  "item": [
    {"name": "OAuth req", "request": {"method": "GET", "url": "https://x.test/a", "auth": {"type": "oauth2"}}},
    {"name": "Form req", "request": {"method": "POST", "url": "https://x.test/b", "body": {"mode": "formdata", "formdata": [{"key": "f", "value": "v"}]}}},
    {"name": "Dup", "request": {"method": "GET", "url": "https://x.test/c"}},
    {"name": "Dup", "request": {"method": "GET", "url": "https://x.test/d"}}
  ]
}
JSON
out=$("$BIN" import "$tmp/unsupported.json")
printf '%s' "$out" | jq -e '.requestCount == 4
  and (.warnings | length) == 2
  and (.warnings[0] | contains("OAuth req") and contains("oauth2"))
  and (.warnings[1] | contains("Form req") and contains("formdata"))' >/dev/null \
  && pass "import warns on unsupported auth/body and keeps going" || fail "import warnings: $out"
path=$(jq -r '.path' <<<"$out")
jq -e '(.requests | map(.name)) == ["OAuth req", "Form req", "Dup", "Dup (2)"]' "$path" >/dev/null \
  && pass "import de-dupes colliding request names" || fail "import dedupe: $(cat "$path")"

# ------------------------------------------------------------- postman export
out=$("$BIN" export jsonplaceholder-api)
printf '%s' "$out" | jq -e '.info.name == "JSONPlaceholder API"
  and (.item | length) == 42
  and (.variable[0].key == "baseUrl") and (.variable[0].value == "https://jsonplaceholder.typicode.com")' >/dev/null \
  && pass "export produces a Postman collection from a group" || fail "export: $out"

printf '%s' "$out" | jq -e '[.item[] | select(.name == "Posts / Create Post")][0].request
  | .method == "POST" and .url.raw == "{{baseUrl}}/posts" and .body.mode == "raw"
  and (.header[0].key == "Content-Type")' >/dev/null \
  && pass "export carries method/url/body/headers through" || fail "export request shape: $out"

"$BIN" export nope-slug >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "export: unknown slug -> error JSON and non-zero exit" || fail "export unknown slug (rc=$rc): $(cat "$tmp/o.json")"

# Panel.qml's Process spawns http-groups without a shell (argv, no execve
# through /bin/sh), so a leading ~ the user types into the Import field is
# never shell-expanded — http-groups must expand it itself.
cp "$FIXTURE" "$tmp/collection.json"
tildeOut=$(HOME="$tmp" "$BIN" import '~/collection.json')
printf '%s' "$tildeOut" | jq -e '.requestCount == 42' >/dev/null \
  && pass "import expands a leading ~ to \$HOME (no shell runs it for us)" || fail "import tilde path: $tildeOut"

# Round trip: importing what we just exported should resolve the same URL.
printf '%s' "$out" >"$tmp/exported.json"
reimported=$(jq -nc --slurpfile collection "$tmp/exported.json" --arg overrideName "" -f "$HERE/../lib/postman-import.jq")
jq -e '(.group.requests | map(select(.name == "Posts / Get All Posts")) | .[0].path) == "{{baseUrl}}/posts"' \
  <<<"$reimported" >/dev/null \
  && pass "export -> import round-trips a request's URL" || fail "round trip: $reimported"

# ---- import/export secrets are not exposed to jq's own argv -----------------
# `import`/`export` used to pass the whole Postman collection / group JSON to
# `jq` via `--argjson name "$(<file)"`, putting a collection or group's auth
# token/password on that jq process's own argv (readable by other local
# users via `ps`/`/proc/<pid>/cmdline` for as long as it runs). `bash -x`
# records each command's fully-expanded argv as it's about to run, which is a
# precise, non-racy way to check for that — unlike scraping
# /proc/<pid>/cmdline, which would need to win a timing race against a jq
# process that usually exits in milliseconds.
cat >"$tmp/secret-import.json" <<'JSON'
{
  "info": {"name": "Secret Collection"},
  "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "s3cr3t-import-XYZ"}]},
  "item": [{"name": "Req", "request": {"method": "GET", "url": "https://x.test/a"}}]
}
JSON
bash -x "$BIN" import "$tmp/secret-import.json" >"$tmp/import-xtrace.out" 2>"$tmp/import-xtrace.err"
if grep -E '^[+]+ jq ' "$tmp/import-xtrace.err" | grep -F -- "s3cr3t-import-XYZ" >/dev/null; then
  fail "import does not expose the collection auth token via jq argv"
else
  pass "import does not expose the collection auth token via jq argv"
fi
printf '%s' "$(<"$tmp/import-xtrace.out")" | jq -e '.requestCount == 1' >/dev/null \
  && pass "import with hidden-argv secret still succeeds" || fail "hidden-argv import: $(<"$tmp/import-xtrace.out")"

cat >"$tmp/groups/secret-export.json" <<'JSON'
{"name":"SecretExport","baseUrl":"https://x.test","auth":{"type":"bearer","token":"s3cr3t-export-ABC"},
 "headers":{},"environments":{},"activeEnv":"","requests":[{"name":"Req","method":"GET","path":"/a"}]}
JSON
bash -x "$BIN" export secret-export >"$tmp/export-xtrace.out" 2>"$tmp/export-xtrace.err"
if grep -E '^[+]+ jq ' "$tmp/export-xtrace.err" | grep -F -- "s3cr3t-export-ABC" >/dev/null; then
  fail "export does not expose the group auth token via jq argv"
else
  pass "export does not expose the group auth token via jq argv"
fi
printf '%s' "$(<"$tmp/export-xtrace.out")" | jq -e '.auth.bearer[0].value == "s3cr3t-export-ABC"' >/dev/null \
  && pass "export with hidden-argv secret still prints the token" || fail "hidden-argv export: $(<"$tmp/export-xtrace.out")"

# ------------------------------------------------------------- delete
path="$tmp/groups/jsonplaceholder-api.json"
out=$("$BIN" delete jsonplaceholder-api)
printf '%s' "$out" | jq -e --arg path "$path" '.slug == "jsonplaceholder-api" and .path == $path and .deleted == true' >/dev/null \
  && pass "delete removes the group and reports what was deleted" || fail "delete: $out"
[[ ! -e $path ]] && pass "delete: file is actually gone" || fail "delete: file still exists at $path"

"$BIN" delete jsonplaceholder-api >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "delete: already-gone slug -> error JSON and non-zero exit" || fail "delete missing (rc=$rc): $(cat "$tmp/o.json")"

"$BIN" delete "" >"$tmp/o.json"; rc=$?
[[ $rc -ne 0 ]] && jq -e '.error | length > 0' "$tmp/o.json" >/dev/null \
  && pass "delete: empty slug -> error JSON and non-zero exit" || fail "delete empty (rc=$rc): $(cat "$tmp/o.json")"

# ------------------------------------------------ file/dir permissions under a permissive umask
# Group files can hold saved API keys/passwords; under a normal 022 umask
# they must not become group/world readable.
permtmp=$(mktemp -d)
export OMARCHY_HTTP_GROUPS_DIR="$permtmp/groups"
(
  umask 022
  "$BIN" new "Perms" >/dev/null
  cp "$FIXTURE" "$permtmp/perms-import.json"
  "$BIN" import "$permtmp/perms-import.json" "Perms Import" >/dev/null
)
dirMode=$(stat -c '%a' "$permtmp/groups")
[[ $dirMode == "700" ]] && pass "new: group dir is created 700 regardless of umask" \
  || fail "group dir mode: $dirMode"
newMode=$(stat -c '%a' "$permtmp/groups/perms.json")
[[ $newMode == "600" ]] && pass "new: group file is created 600 regardless of umask" \
  || fail "new file mode: $newMode"
importMode=$(stat -c '%a' "$permtmp/groups/perms-import.json")
[[ $importMode == "600" ]] && pass "import: group file is created 600 regardless of umask" \
  || fail "import file mode: $importMode"
rm -rf "$permtmp"
export OMARCHY_HTTP_GROUPS_DIR="$tmp/groups"

# ------------------------------------------------ list repairs pre-existing modes
# `new`/`import` create 0700/0600, but a group directory or file written by an
# earlier version stays 0755/0644 with saved API keys and passwords in it.
# `list` is what the panel runs on every open, so it is what repairs them.
repairtmp=$(mktemp -d)
export OMARCHY_HTTP_GROUPS_DIR="$repairtmp/groups"
mkdir -p "$repairtmp/groups"
chmod 755 "$repairtmp/groups"
printf '{"name":"Legacy","auth":{"type":"bearer","token":"LEGACY-TOKEN"}}\n' >"$repairtmp/groups/legacy.json"
chmod 644 "$repairtmp/groups/legacy.json"

out=$("$BIN" list)
printf '%s' "$out" | jq -e 'length == 1 and .[0].slug == "legacy" and .[0].name == "Legacy"' >/dev/null \
  && pass "list still reports a group it had to repair" || fail "list after repair: $out"
dirMode=$(stat -c '%a' "$repairtmp/groups")
[[ $dirMode == "700" ]] && pass "list repairs a 755 group dir to 700" || fail "repaired dir mode: $dirMode"
fileMode=$(stat -c '%a' "$repairtmp/groups/legacy.json")
[[ $fileMode == "600" ]] && pass "list repairs a 644 group file to 600" || fail "repaired file mode: $fileMode"
rm -rf "$repairtmp"
export OMARCHY_HTTP_GROUPS_DIR="$tmp/groups"

exit $((fails > 0 ? 1 : 0))
