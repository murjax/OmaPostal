const assert = require("assert")
const G = require("./load-lib")("lib/groups.js")

const group = { name: "T", headers: { Accept: "a", "X-Both": "g" }, requests: [{ name: "One", method: "GET", path: "/1" }] }

let g = G.upsertRequest(group, { name: "Two", method: "POST", path: "/2" })
assert.deepStrictEqual(g.requests.map(r => r.name), ["One", "Two"], "upsert appends a new name")
assert.strictEqual(group.requests.length, 1, "upsert does not mutate its input")

g = G.upsertRequest(g, { name: "One", method: "PUT", path: "/1b" })
assert.deepStrictEqual(g.requests.map(r => [r.name, r.method]), [["One", "PUT"], ["Two", "POST"]], "upsert replaces same name in place")

g = G.removeRequest(g, "One")
assert.deepStrictEqual(g.requests.map(r => r.name), ["Two"], "remove drops the named request")
assert.deepStrictEqual(G.removeRequest({ name: "x" }, "a").requests, [], "remove tolerates a group without requests")

assert.deepStrictEqual(
  G.inheritedHeaders(group, { "x-both": "r" }),
  [{ key: "Accept", value: "a", overridden: false }, { key: "X-Both", value: "g", overridden: true }],
  "inherited headers flag case-insensitive overrides")
assert.deepStrictEqual(G.inheritedHeaders(null, {}), [], "no group -> no inherited headers")

assert.deepStrictEqual(
  G.buildRequest("N", { method: "POST", url: "/p", headers: { A: "1" }, body: "b" }),
  { name: "N", method: "POST", path: "/p", headers: { A: "1" }, body: "b", auth: "inherit" },
  "buildRequest maps url->path and defaults auth to inherit")
assert.strictEqual(G.buildRequest("N", { auth: "none" }).auth, "none", "buildRequest keeps an explicit auth")

console.log("ok   - groups.js")
