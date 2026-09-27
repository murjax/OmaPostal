# Convert a murjax.omapostal group into a Postman v2.1 collection.
# Input: $group arrives via --slurpfile (not --argjson) so the whole group —
# which can carry a bearer token, API key, or basic-auth password — never
# appears in this jq process's own argv/cmdline, only the file path does;
# $group[0] below unwraps the slurped single-element array back into a
# plain object.
# Output: the collection JSON (printed as-is by the caller).
#
# Only the group's *active* environment round-trips (as collection variables)
# — Postman collections don't carry multiple named environments. Requests
# keep a flat "item" list (no folders); a request's saved name may itself
# contain " / " if it came from an earlier import of a foldered collection.

include "url";

$group[0] as $group |

def slugify(s):
  (s // "collection") | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "");

def headersOut(h):
  (h // {}) | to_entries | map({key: .key, value: (.value | tostring), type: "text"});

# null for "none"/unrecognized types (caller omits the auth key in that case).
def convertAuthOut(a):
  if (a.type // "none") == "bearer" then
    {type: "bearer", bearer: [{key: "token", value: (a.token // ""), type: "string"}]}
  elif (a.type // "none") == "basic" then
    {type: "basic", basic: [
      {key: "username", value: (a.username // ""), type: "string"},
      {key: "password", value: (a.password // ""), type: "string"}]}
  elif (a.type // "none") == "apiKey" then
    {type: "apikey", apikey: [
      {key: "key", value: (a.name // ""), type: "string"},
      {key: "value", value: (a.value // ""), type: "string"},
      {key: "in", value: (a["in"] // "header"), type: "string"}]}
  else null
  end;

($group.requests // []) | map(
  . as $r
  | {
      name: $r.name,
      request: (
        {
          method: ($r.method // "GET"),
          header: headersOut($r.headers),
          url: {raw: join_url($group.baseUrl // ""; $r.path // "")}
        }
        + (if (($r.body // "") | length) > 0 then {body: {mode: "raw", raw: $r.body}} else {} end)
        + (
            if ($r.auth == "inherit" or $r.auth == null) then {}
            elif ($r.auth == "none") then {auth: {type: "noauth"}}
            else (convertAuthOut($r.auth)) as $ca | (if $ca == null then {} else {auth: $ca} end)
            end
          )
      ),
      response: []
    }
) as $items
| (convertAuthOut($group.auth // {type: "none"})) as $collectionAuth
| (($group.environments // {})[$group.activeEnv // ""] // {}) as $activeVars
| {
    info: {
      _postman_id: ("murjax-" + slugify($group.name)),
      name: ($group.name // "Exported collection"),
      schema: "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
    },
    variable: ($activeVars | to_entries | map({key: .key, value: (.value | tostring), type: "string"})),
    item: $items
  }
  + (if $collectionAuth == null then {} else {auth: $collectionAuth} end)
