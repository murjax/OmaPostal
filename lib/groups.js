.pragma library

function clone(v) { return JSON.parse(JSON.stringify(v)) }

// Replace the request with the same name, or append it. Returns a copy.
function upsertRequest(group, req) {
  var g = clone(group)
  g.requests = g.requests || []
  for (var i = 0; i < g.requests.length; i++) {
    if (g.requests[i].name === req.name) { g.requests[i] = req; return g }
  }
  g.requests.push(req)
  return g
}

function removeRequest(group, name) {
  var g = clone(group)
  g.requests = (g.requests || []).filter(function (r) { return r.name !== name })
  return g
}

// Group default headers as display rows; `overridden` marks the ones a request
// header of the same name (case-insensitive) replaces.
function inheritedHeaders(group, own) {
  var mine = Object.keys(own || {}).map(function (k) { return k.toLowerCase() })
  var defaults = (group && group.headers) || {}
  return Object.keys(defaults).map(function (k) {
    return { key: k, value: String(defaults[k]), overridden: mine.indexOf(k.toLowerCase()) >= 0 }
  })
}

function buildRequest(name, state) {
  return {
    name: name,
    method: state.method || "GET",
    path: state.url || "",
    headers: state.headers || {},
    body: state.body || "",
    auth: state.auth === undefined ? "inherit" : state.auth
  }
}
