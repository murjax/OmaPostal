const assert = require("assert")
const S = require("./load-lib")("lib/secure.js")

// A fresh gate holds writes back: http-secure has not run yet, so FileView
// would create the file 0644 and the directory 0755.
let g = S.create()
assert.strictEqual(S.isReady(g), false, "a fresh gate is not ready")
let ran = []
assert.strictEqual(S.check(g, () => ran.push("a")), "wait", "a write before http-secure waits")
assert.strictEqual(S.check(g, () => ran.push("b")), "wait", "a second write waits too")
assert.deepStrictEqual(ran, [], "nothing runs while securing is pending")

// ...and is released, in order, once http-secure succeeds.
let queued = S.settle(g, true, "")
assert.strictEqual(S.isReady(g), true, "the gate is ready after a successful run")
queued.forEach(fn => fn())
assert.deepStrictEqual(ran, ["a", "b"], "deferred writes rerun in the order they were queued")
assert.deepStrictEqual(S.settle(g, true, "").length, 0, "the queue is drained, not replayed")

// Once ready, a write goes straight through rather than being queued again.
assert.strictEqual(S.check(g, () => ran.push("c")), "go", "a write after securing goes through")
assert.deepStrictEqual(ran, ["a", "b"], "a 'go' caller writes itself; the gate does not call it")

// A later panel open repairs again, so writes wait on that run too.
S.markRunning(g)
assert.strictEqual(S.isReady(g), false, "a repair run makes the gate not ready again")
assert.strictEqual(S.check(g, () => ran.push("d")), "wait", "a write during a repair run waits")

// A failed run refuses the write outright: writing anyway is what would leave
// the credential world-readable. Queued callers are rerun so each reports it.
queued = S.settle(g, false, "cannot chmod 700 /run/user/1000/murjax.omapostal")
assert.strictEqual(queued.length, 1, "a failed run still hands back what it deferred")
assert.strictEqual(S.check(g, () => ran.push("e")), "refuse", "a rerun caller is refused, not requeued")
assert.deepStrictEqual(ran, ["a", "b"], "a refused write never happens")
assert.strictEqual(g.error, "cannot chmod 700 /run/user/1000/murjax.omapostal", "the failure is reportable")
assert.strictEqual(S.check(g, () => ran.push("f")), "refuse", "later writes stay refused")

// Reopening the panel retries: markRunning clears the previous failure.
S.markRunning(g)
assert.strictEqual(g.error, "", "a retry clears the stale error")
assert.strictEqual(S.check(g, () => ran.push("g")), "wait", "a retry queues writes again")
S.settle(g, true, "").forEach(fn => fn())
assert.deepStrictEqual(ran, ["a", "b", "g"], "a write deferred across a retry still lands")

console.log("ok   - secure.js")
