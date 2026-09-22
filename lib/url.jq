# Join a group's baseUrl with a request path/URL. Shared by resolve.jq
# (live sends) and postman-export.jq, so both agree on the same rules:
# absolute $t wins outright; otherwise $base's trailing slashes are trimmed
# and exactly one slash is inserted unless $t already starts with "/" or "?".
def join_url($base; $t):
  if ($t | test("^https?://")) then $t
  elif $base == "" then $t
  else ($base | sub("/+$"; ""))
    + (if $t == "" then ""
       elif ($t | startswith("/")) or ($t | startswith("?")) then $t
       else "/" + $t end)
  end;
