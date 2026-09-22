.pragma library

// Identity of a history entry: what was sent, and where. Auth is excluded (it
// is masked and never stored); header names compare case-insensitively.
function identityKey(entry) {
  var h = entry.headers || {}
  var pairs = Object.keys(h)
    .map(function (k) { return [k.toLowerCase(), String(h[k])] })
    .sort(function (a, b) { return a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0) })
  return JSON.stringify([entry.method || "GET", entry.url || "", pairs,
    entry.body || "", entry.group || "", entry.env || ""])
}

// Keep the first (newest) entry for each identity; the list is newest-first.
function dedupe(list) {
  var seen = {}
  return (list || []).filter(function (e) {
    var k = identityKey(e)
    if (seen[k]) return false
    seen[k] = true
    return true
  })
}

// Put `entry` on top, dropping any earlier entry with the same identity, then
// trim to `limit`.
function insertEntry(list, entry, limit) {
  var k = identityKey(entry)
  var rest = (list || []).filter(function (e) { return identityKey(e) !== k })
  return [entry].concat(rest).slice(0, limit)
}

// True if `entry` was sent through a group (as opposed to ad-hoc).
function hadGroup(entry) {
  return !!(entry && (entry.groupPath || entry.group))
}

// `headers` with values equal to the "••••" auth placeholder removed, so a
// masked value is never resent as a literal credential.
function stripMasked(headers) {
  var h = headers || {}
  var out = {}
  Object.keys(h).forEach(function (k) { if (h[k] !== "••••") out[k] = h[k] })
  return out
}

// The {method,url,headers,body} to load into the editor for a history entry.
// A group-mode entry stores the group-relative, unsubstituted request (path,
// own headers, raw {{vars}}) plus, since it was sent, a `resolved` snapshot
// of what was actually sent (substituted URL/headers/body, auth masked).
// While the group still exists (`known`), the relative fields are used, so
// the entry stays editable against the group. Once the group is gone, the
// relative fields can no longer be resolved (no baseUrl, no vars, no
// inherited headers) — so this falls back to the resolved snapshot instead,
// which is still a valid ad-hoc request. Masked auth headers are dropped
// rather than resent literally. An ad-hoc entry, or a group entry that
// predates this snapshot, is returned unchanged.
function replayState(entry, known) {
  if (hadGroup(entry) && !known && entry.resolved) {
    return {
      method: entry.resolved.method || entry.method,
      url: entry.resolved.url || entry.url,
      headers: stripMasked(entry.resolved.headers || entry.headers),
      body: entry.resolved.body !== undefined ? entry.resolved.body : entry.body
    }
  }
  return entry
}
