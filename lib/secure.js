.pragma library

// The gate every FileView write that can carry a credential has to pass.
//
// Quickshell's FileView has no file-mode option: it creates a missing parent
// directory 0755 and a new file 0644, so bin/http-secure has to make the
// plugin's private directory 0700 and its files 0600 before anything is
// written to them. But http-secure is a process, so it settles several event
// loop turns after the panel opens — long enough for a send() in that window
// to write the request's own Authorization header into a world-readable file
// inside a world-traversable directory, with the repair landing only after
// the secret was already exposed.
//
// So those writes wait here instead. The gate is a plain object rather than
// QML state so the ordering can be unit-tested without a running shell:
//
//   {state: "idle" | "running" | "ready" | "failed", pending: [fn], error: ""}

// A fresh gate, before http-secure has been started.
function create() {
  return { state: "idle", pending: [], error: "" }
}

// True once the private directory and files are known to be 0700/0600.
function isReady(gate) {
  return gate.state === "ready"
}

// http-secure has been started. Also used on a later panel open, which repairs
// again: nothing is known to be secure until that run exits either.
function markRunning(gate) {
  gate.state = "running"
  gate.error = ""
}

// What the caller should do with a write that can contain a credential:
//   "go"      - the files are secure; write now.
//   "wait"    - fn has been queued and will be rerun once http-secure settles.
//   "refuse"  - securing failed; do not write, and report gate.error.
function check(gate, fn) {
  if (gate.state === "ready") return "go"
  if (gate.state === "failed") return "refuse"
  gate.pending.push(fn)
  return "wait"
}

// http-secure exited. Returns the deferred actions, in the order they were
// queued, for the caller to rerun. They are rerun after a failure too, so that
// each one reports the refusal in its own part of the UI (check() answers
// "refuse") rather than being dropped without a word.
function settle(gate, ok, error) {
  gate.state = ok ? "ready" : "failed"
  gate.error = ok ? "" : error
  var queued = gate.pending
  gate.pending = []
  return queued
}
