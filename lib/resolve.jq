# Resolve a group-mode request into a concrete request.
# Inputs (--argjson/--arg): $req (the request file), $group (the group file),
# $envName ("" = use the group's activeEnv).
# Output: {ok:true, method, url, headers, body, resolved:{method,url,headers}}
#      or {ok:false, error}. `resolved` is what the UI shows: auth is masked.
include "url";

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
# the masked variants are "••••" so tokens never reach the UI or history.
def apply_auth($auth; $headers; $url):
  def hdr($k; $v):
    {headers: merge_headers($headers; {($k): $v}),
     maskedHeaders: merge_headers($headers; {($k): "••••"}),
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
         maskedUrl: ($url + $sep + ($auth.name | @uri) + "=••••")}
    else hdr($auth.name; ($auth.value // "")) end
  else error("unknown auth type: " + ($auth.type | tostring)) end;

try (
  envvars as $vars
  | (saved_request + ($req | del(.groupFile, .env, .requestName, .timeoutSec))) as $raw
  | ($raw | del(.auth) | substitute($vars)) as $r
  | pick_auth($raw; $vars) as $auth
  | (($group.baseUrl // "") | substitute($vars)) as $base
  | merge_headers((($group.headers // {}) | substitute($vars)); ($r.headers // {})) as $headers
  | join_url($base; ($r.path // $r.url // "")) as $url
  | apply_auth($auth; $headers; $url) as $a
  | {ok: true, method: ($r.method // "GET"), url: $a.url, headers: $a.headers, body: ($r.body // ""),
     resolved: {method: ($r.method // "GET"), url: $a.maskedUrl, headers: $a.maskedHeaders, body: ($r.body // "")}}
) catch {ok: false, error: (if type == "string" then . else tojson end)}
