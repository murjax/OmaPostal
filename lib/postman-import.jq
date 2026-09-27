# Convert a Postman v2.x collection into a murjax.omapostal group.
# Inputs: $collection arrives via --slurpfile (not --argjson) so the whole
# collection — which can carry a bearer token, API key, or basic-auth
# password in its own auth block or a request's — never appears in this jq
# process's own argv/cmdline, only the file path does; $collection[0] below
# unwraps the slurped single-element array back into a plain object.
# $overrideName ("" = use the collection's own name) is passed via --arg
# since it's just a label, not sensitive.
# Output: {group: {...}, warnings: [...], requestCount: N}
#
# Folders flatten into request names joined by " / " (groups have no
# folders). Collection variables become one "default" environment. Unsupported
# auth types (anything but bearer/basic/apikey/noauth) and body modes (anything
# but raw/urlencoded/graphql) are dropped with a warning rather than failing
# the import.

$collection[0] as $collection |

def urlOf(u):
  if (u == null) then ""
  elif (u | type) == "object" then (u.raw // "")
  else (u | tostring)
  end;

def flatten(prefix):
  if (.item? != null) then
    (.name // "") as $mine
    | (.item[] | flatten(prefix + [$mine]))
  else
    {name: (prefix + [(.name // "request")] | join(" / ")), request: (.request // {})}
  end;

def headersOf(h):
  (h // []) | map(select(.disabled != true)) | map({(.key): (.value // "")}) | add // {};

def bodyOf(b):
  if (b == null) then {body: "", warning: null}
  elif (b.mode // "") == "raw" then {body: (b.raw // ""), warning: null}
  elif (b.mode // "") == "urlencoded" then
    {body: ((b.urlencoded // []) | map(select(.disabled != true))
            | map(((.key // "") | @uri) + "=" + ((.value // "") | @uri)) | join("&")),
     warning: null}
  elif (b.mode // "") == "graphql" then
    {body: ((b.graphql.query) // ""),
     warning: "body mode 'graphql' only partially supported — variables were dropped"}
  else
    {body: "", warning: ("body mode '" + (b.mode // "unknown") + "' is not supported — body was dropped")}
  end;

def convertAuth(a):
  if (a.type // "") == "bearer" then
    {ok: {type: "bearer", token: (((a.bearer // []) | map(select(.key == "token")) | .[0].value) // "")}}
  elif (a.type // "") == "basic" then
    {ok: {type: "basic",
          username: (((a.basic // []) | map(select(.key == "username")) | .[0].value) // ""),
          password: (((a.basic // []) | map(select(.key == "password")) | .[0].value) // "")}}
  elif (a.type // "") == "apikey" then
    {ok: {type: "apiKey",
          name: (((a.apikey // []) | map(select(.key == "key")) | .[0].value) // ""),
          value: (((a.apikey // []) | map(select(.key == "value")) | .[0].value) // ""),
          "in": (((a.apikey // []) | map(select(.key == "in")) | .[0].value) // "header")}}
  else
    {err: (a.type // "unknown")}
  end;

# Request-level: missing auth means "inherit" from the group.
def reqAuthOf(a):
  if (a == null) then {auth: "inherit", warning: null}
  elif (a.type // "") == "noauth" then {auth: "none", warning: null}
  else (convertAuth(a)) as $c
    | if ($c.ok != null) then {auth: $c.ok, warning: null}
      else {auth: "none", warning: ("auth type '" + $c.err + "' is not supported — imported without auth")}
      end
  end;

# Collection-level: missing auth means "none".
def groupAuthOf(a):
  if (a == null) then {auth: {type: "none"}, warning: null}
  elif (a.type // "") == "noauth" then {auth: {type: "none"}, warning: null}
  else (convertAuth(a)) as $c
    | if ($c.ok != null) then {auth: $c.ok, warning: null}
      else {auth: {type: "none"}, warning: ("collection auth type '" + $c.err + "' is not supported — imported without default auth")}
      end
  end;

def varsOf(vars):
  (vars // []) | map(select(.disabled != true)) | map({(.key): ((.value // "") | tostring)}) | add // {};

# First occurrence of a name is kept as-is; later ones get " (2)", " (3)", ...
def dedupeNames(reqs):
  reduce reqs[] as $r
    ({seen: {}, out: []};
      ($r.name) as $n
      | (.seen[$n] // 0) as $c
      | ($c + 1) as $next
      | (if $c == 0 then $n else ($n + " (" + ($next | tostring) + ")") end) as $finalName
      | {seen: (.seen + {($n): $next}), out: (.out + [$r + {name: $finalName}])}
    )
  | .out;

($collection.item // [])
| [.[] | flatten([])]
| dedupeNames(.)
| map(
    . as $leaf
    | (reqAuthOf($leaf.request.auth)) as $a
    | (bodyOf($leaf.request.body)) as $b
    | {
        req: {
          name: $leaf.name,
          method: ($leaf.request.method // "GET"),
          path: urlOf($leaf.request.url),
          headers: headersOf($leaf.request.header),
          body: $b.body,
          auth: $a.auth
        },
        warnings: ([$a.warning, $b.warning] | map(select(. != null)) | map($leaf.name + ": " + .))
      }
  ) as $items
| ($items | map(.req)) as $requests
| ($items | map(.warnings) | add // []) as $itemWarnings
| (groupAuthOf($collection.auth)) as $ga
| (varsOf($collection.variable)) as $vars
| (if ($overrideName | length) > 0 then $overrideName else ($collection.info.name // "Imported collection") end) as $name
| {
    group: {
      name: $name,
      baseUrl: "",
      headers: {},
      auth: $ga.auth,
      environments: (if ($vars | length) > 0 then {default: $vars} else {} end),
      activeEnv: (if ($vars | length) > 0 then "default" else "" end),
      requests: $requests
    },
    warnings: ((if $ga.warning == null then [] else [$ga.warning] end) + $itemWarnings),
    requestCount: ($requests | length)
  }
