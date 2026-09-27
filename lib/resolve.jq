# Resolve a group-mode request into a concrete request.
# Inputs: $req and $group arrive via --slurpfile (not --argjson) so the full
# request/group JSON — which can carry an Authorization value, password, or
# API key — never appears in this jq process's own argv/cmdline, only the
# file paths do; $req[0]/$group[0] below unwrap the slurped single-element
# arrays back into plain objects for the rest of the program. $envName
# ("" = use the group's activeEnv) is passed via --arg since it's just a
# label, not sensitive.
# Output: {ok:true, method, url, headers, body, resolved:{method,url,headers,body}}
#      or {ok:false, error}. `resolved` is the snapshot the UI shows and the
# history file stores; every credential in it is masked — see is_secret_name.
include "url";

$req[0] as $req | $group[0] as $group |

def MASK: "\u2022\u2022\u2022\u2022";

# A name whose value is treated as a credential wherever it turns up: a header
# name, an environment variable name, or a URL query parameter name.
#
# Masking used to key off provenance — only the value apply_auth itself
# injected was masked — which missed the shapes that occur most often in
# practice, all of them unmasked in `resolved` and so unmasked in the history
# file: a group with auth.type "none" whose requests carry
# "Authorization: Bearer {{accessToken}}" as an ordinary header, a {{token}} in
# a query string, or a {{refreshToken}} in a JSON body. An imported Postman
# collection produces exactly those, since Postman expresses auth as collection
# variables far more often than as an auth block. Keying off the name instead
# means a credential is masked wherever it appears, whoever put it there.
def is_secret_name:
  ascii_downcase
  | test("authorization|^cookie$|^set-cookie$|token|secret|passwd|password|credential|signature|^sig$|^auth$|^x-auth|api[-_]?key|apikey|access[-_]?key|private[-_]?key|session[-_]?id|^key$|bearer");

# Replace the values of secret-named keys with the placeholder. Used both for
# an object of headers and for an environment's variables.
def mask_by_name: with_entries(if (.key | is_secret_name) then .value = MASK else . end);

# Mask the value of any secret-named query parameter. apply_auth already masks
# the one it appends for an apiKey-in-query auth; this covers a token the user
# (or an imported collection) put in the query string themselves.
def mask_query:
  (index("?")) as $i
  | if $i == null then .
    else .[:$i] + "?" + (.[$i+1:] | split("&") | map(
        (index("=")) as $e
        | if $e == null then .
          elif (.[:$e] | is_secret_name) then .[:$e] + "=" + MASK
          else . end)
      | join("&"))
    end;

def substitute($vars):
  walk(if type == "string" then
    gsub("\\{\\{\\s*(?<n>[^{}\\s]+)\\s*\\}\\}";
      .n as $n
      | if ($vars | has($n)) then ($vars[$n] | tostring)
        else error("undefined variable: " + $n) end)
  else . end);

# $b wins over $a; header names compare case-insensitively.
def merge_headers($a; $b):
  ($b | keys | map(ascii_downcase)) as $bk
  | ($a | with_entries(.key as $k | select(($bk | any(. == ($k | ascii_downcase))) | not))) + $b;

def envvars:
  ($group.environments // {}) as $envs
  | (if $envName != "" then $envName else ($group.activeEnv // "") end) as $name
  | if $name == "" then {}
    elif ($envs | has($name)) then $envs[$name]
    else error("unknown environment: " + $name) end;

def saved_request:
  if ($req.requestName // "") == "" then {}
  else (($group.requests // []) | map(select(.name == $req.requestName)) | .[0])
    // error("unknown request: " + $req.requestName)
  end;

# "inherit" (or absent) -> the group's auth; "none" -> none; object -> override.
def pick_auth($raw; $vars):
  ($raw.auth // "inherit") as $a
  | if $a == "inherit" then
      (($group.auth // {type: "none"}) | if type == "string" then {type: .} else . end | substitute($vars))
    elif $a == "none" then {type: "none"}
    else ($a | substitute($vars)) end;

# {headers, maskedHeaders, url, maskedUrl} after applying $auth. Values shown in
# the masked variants are the placeholder so tokens never reach the UI or history.
def apply_auth($auth; $headers; $url):
  def hdr($k; $v):
    {headers: merge_headers($headers; {($k): $v}),
     maskedHeaders: merge_headers($headers; {($k): MASK}),
     url: $url, maskedUrl: $url};
  if ($auth.type // "none") == "none" then
    {headers: $headers, maskedHeaders: $headers, url: $url, maskedUrl: $url}
  elif $auth.type == "bearer" then hdr("Authorization"; "Bearer " + ($auth.token // ""))
  elif $auth.type == "basic" then
    hdr("Authorization"; "Basic " + ((($auth.username // "") + ":" + ($auth.password // "")) | @base64))
  elif $auth.type == "apiKey" then
    if ($auth["in"] // "header") == "query" then
      (if ($url | contains("?")) then "&" else "?" end) as $sep
      | {headers: $headers, maskedHeaders: $headers,
         url: ($url + $sep + ($auth.name | @uri) + "=" + (($auth.value // "") | @uri)),
         maskedUrl: ($url + $sep + ($auth.name | @uri) + "=" + MASK)}
    else hdr($auth.name; ($auth.value // "")) end
  else error("unknown auth type: " + ($auth.type | tostring)) end;

# The whole resolution, for one set of environment variables.
def resolve($vars):
  (saved_request + ($req | del(.groupFile, .env, .requestName, .timeoutSec))) as $raw
  | ($raw | del(.auth) | substitute($vars)) as $r
  | pick_auth($raw; $vars) as $auth
  | (($group.baseUrl // "") | substitute($vars)) as $base
  | merge_headers((($group.headers // {}) | substitute($vars)); ($r.headers // {})) as $headers
  | join_url($base; ($r.path // $r.url // "")) as $url
  | apply_auth($auth; $headers; $url) as $a
  | {method: ($r.method // "GET"), url: $a.url, headers: $a.headers, body: ($r.body // ""),
     maskedUrl: $a.maskedUrl, maskedHeaders: $a.maskedHeaders};

# Run the resolution twice: once with the real environment, which is what gets
# sent, and once with secret-named variables replaced by the placeholder, which
# is what `resolved` reports. Masking the variables rather than the output is
# what lets a substituted credential be masked inside the request body too —
# the body is an opaque string, so there is no other way to find one in it.
# (A credential typed into the body literally, rather than through a variable,
# is not masked here, and cannot usefully be: the history entry stores the
# request's own body alongside `resolved` regardless.)
# mask_by_name/mask_query then cover credentials that never came from a
# variable at all: an "Authorization: <literal>" header on the group or
# request, or a "?token=..." already in the URL.
# Both passes see the same variable names, so both fail the same way on an
# undefined one.
try (
  envvars as $vars
  | resolve($vars) as $real
  | resolve($vars | mask_by_name) as $shown
  | {ok: true, method: $real.method, url: $real.url, headers: $real.headers, body: $real.body,
     resolved: {method: $shown.method,
                url: ($shown.maskedUrl | mask_query),
                headers: ($shown.maskedHeaders | mask_by_name),
                body: $shown.body}}
) catch {ok: false, error: (if type == "string" then . else tojson end)}
