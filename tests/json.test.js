const assert = require("assert")
const J = require("./load-lib")("lib/json.js")

assert.deepStrictEqual(J.tryParse("[1,2]", null), [1, 2], "parses valid JSON")
assert.strictEqual(J.tryParse("not json", null), null, "falls back to the given value on invalid JSON")
assert.deepStrictEqual(J.tryParse("not json", []), [], "falls back to a non-null value when given one")
assert.strictEqual(J.tryParse("not json"), null, "defaults the fallback to null when omitted")

console.log("ok   - json.js")
