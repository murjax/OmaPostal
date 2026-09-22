// Load a QML `.pragma library` JS file under node: strip the pragma, evaluate,
// and return every top-level function by name.
const fs = require("fs")
const path = require("path")

module.exports = function load(rel) {
  const src = fs.readFileSync(path.join(__dirname, "..", rel), "utf8")
    .split("\n").filter(l => !l.startsWith(".pragma")).join("\n")
  const names = [...src.matchAll(/^function (\w+)/gm)].map(m => m[1])
  return new Function(src + "\nreturn {" + names.join(",") + "}")()
}
