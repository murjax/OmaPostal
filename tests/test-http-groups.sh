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
reimported=$(jq -nc --argjson collection "$out" --arg overrideName "" -f "$HERE/../lib/postman-import.jq")
jq -e '(.group.requests | map(select(.name == "Posts / Get All Posts")) | .[0].path) == "{{baseUrl}}/posts"' \
  <<<"$reimported" >/dev/null \
  && pass "export -> import round-trips a request's URL" || fail "round trip: $reimported"

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

exit $((fails > 0 ? 1 : 0))
