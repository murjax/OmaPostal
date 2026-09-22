const assert = require("assert")
const H = require("./load-lib")("lib/history.js")

const a = { method: "GET", url: "/u", headers: { "X-A": "1" }, body: "", group: "g", env: "dev", ts: 1, status: 200 }

assert.strictEqual(H.identityKey(a), H.identityKey({ ...a, headers: { "x-a": "1" }, ts: 2, status: 500 }),
  "header case, ts and status do not affect identity")
assert.notStrictEqual(H.identityKey(a), H.identityKey({ ...a, env: "prod" }), "env is part of identity")
assert.notStrictEqual(H.identityKey(a), H.identityKey({ ...a, group: "h" }), "group is part of identity")
assert.notStrictEqual(H.identityKey(a), H.identityKey({ ...a, body: "x" }), "body is part of identity")
assert.strictEqual(
  H.identityKey({ method: "GET", url: "/u", headers: { A: "1", B: "2" }, body: "" }),
  H.identityKey({ method: "GET", url: "/u", headers: { B: "2", A: "1" }, body: "" }),
  "header order does not matter")

const b = { ...a, env: "prod", ts: 0 }
const a2 = { ...a, ts: 2, status: 500 }
let out = H.insertEntry([b, a], a2, 20)
assert.deepStrictEqual(out.map(e => [e.env, e.ts]), [["dev", 2], ["prod", 0]], "resend moves entry to top with fresh data")
assert.strictEqual(H.insertEntry([b, a], { ...a, url: "/n" }, 2).length, 2, "insert trims to limit")
assert.strictEqual(H.insertEntry([], a, 5).length, 1, "insert into empty list")

out = H.dedupe([a2, b, a])
assert.deepStrictEqual(out.map(e => [e.env, e.ts]), [["dev", 2], ["prod", 0]], "dedupe keeps the newest of each")
assert.deepStrictEqual(H.dedupe(undefined), [], "dedupe tolerates undefined")

// -------------------------------------------------- replayState (group-gone fallback)

assert.deepStrictEqual(
  H.stripMasked({ "X-Mine": "1", Authorization: "••••" }),
  { "X-Mine": "1" },
  "stripMasked drops header values that are the masked placeholder")
assert.deepStrictEqual(H.stripMasked(undefined), {}, "stripMasked tolerates undefined")

const groupEntry = {
  method: "GET", url: "/users", headers: { "X-Mine": "1" }, body: "{{unresolved}}",
  group: "acme", groupPath: "/groups/acme.json", env: "dev",
  resolved: { method: "GET", url: "http://api.acme.com/v1/users",
    headers: { "X-Mine": "1", Authorization: "••••" }, body: "resolved-body" }
}

assert.strictEqual(H.replayState(groupEntry, true), groupEntry,
  "known group: the group-relative entry is used as-is (still editable against the group)")

assert.deepStrictEqual(H.replayState(groupEntry, false),
  { method: "GET", url: "http://api.acme.com/v1/users", headers: { "X-Mine": "1" }, body: "resolved-body" },
  "gone group with a resolved snapshot: falls back to the already-substituted request, masked auth dropped")

const adhocEntry = { method: "GET", url: "https://example.com", headers: {}, body: "", group: "", env: "" }
assert.strictEqual(H.replayState(adhocEntry, false), adhocEntry,
  "ad-hoc entry (never had a group): used as-is regardless of `known`")

const legacyEntry = { method: "GET", url: "/users", headers: {}, body: "", group: "acme", groupPath: "/groups/acme.json", env: "dev" }
assert.strictEqual(H.replayState(legacyEntry, false), legacyEntry,
  "gone group without a resolved snapshot (entry predates this feature): used as-is")

console.log("ok   - history.js")
