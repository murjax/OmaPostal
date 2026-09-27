import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "lib/history.js" as History
import "lib/groups.js" as Groups
import "lib/json.js" as Json

// Bar widget: a small HTTP client.
//
//   Request tab  - method + URL + Send, with Headers/Body sub-tabs and a
//                  response viewer (status/time/size, body, headers) below.
//   History tab  - the last N requests (newest first); clicking one loads it
//                  back into the Request tab for editing/replay.
//
// Sending shells out to bin/http-send, a curl wrapper that reads a JSON
// request file and prints one JSON result line. History persists to
// ~/.local/state/omarchy/murjax-http-history.json.
Panel {
  id: root
  moduleName: "murjax.omapostal"
  ipcTarget: "murjax.omapostal"
  manageIpc: true

  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace("file://", "") + "/bin"
  readonly property string historyPath: Quickshell.env("HOME") + "/.local/state/omarchy/murjax-http-history.json"
  // XDG_RUNTIME_DIR is per-user and mode 0700; never fall back to the shared,
  // world-writable /tmp for files that can carry a request's Authorization
  // header or other auth in plain text. Falling back under $HOME keeps the
  // same "nobody else can read or symlink-race this" guarantee.
  readonly property string scratchDir: Quickshell.env("XDG_RUNTIME_DIR") || (Quickshell.env("HOME") + "/.cache/omarchy/murjax.omapostal")
  readonly property string requestPath: root.scratchDir + "/murjax-http-request.json"
  readonly property string curlRequestPath: root.scratchDir + "/murjax-http-curl-request.json"

  readonly property int timeoutSec: Math.max(5, parseInt(setting("timeoutSec", 30), 10) || 30)
  readonly property int historyLimit: Math.max(1, parseInt(setting("historyLimit", 20), 10) || 20)

  readonly property var methodOptions: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

  property string method: "GET"
  property string url: ""
  property string body: ""
  property string view: "request"    // "request" | "history"
  property string reqTab: "headers"  // "headers" | "auth" | "body"

  property var reqAuth: "inherit"    // "inherit" | "none" | {type,...}; group mode only

  property bool sending: false
  property bool curlCopying: false
  property int sendSeq: 0            // bumped per send and per cancel; stale results are dropped
  property bool startPending: false  // a send is waiting for a cancelled run to finish exiting
  property var response: null        // {ok,status,statusText,timeMs,sizeBytes,headers,body,truncated,error}
  property var history: []
  property var pendingRequest: null
  readonly property string groupsBin: scriptDir + "/http-groups"
  property var groups: []          // [{slug, name, path}] from `http-groups list`
  property string groupPath: ""    // "" = ad-hoc (no group)
  property var group: null         // parsed group file for groupPath
  property string envName: ""
  property string currentRequestName: ""  // saved request loaded/saved into the editor
  property string pendingEnv: ""   // env to select once the group finishes loading
  property bool creatingGroup: false
  property bool refreshPending: false  // a refresh was requested while a list run was in flight
  property bool importingGroup: false
  property string importMessage: ""  // last import/export result or error, shown inline
  property bool importMessageIsError: false
  property bool confirmOpen: false
  property string confirmMessage: ""
  property var confirmCallback: null

  readonly property color foreground: root.bar.foreground
  readonly property string fontFamily: root.bar.fontFamily
  readonly property color dim: Qt.darker(foreground, 1.4)

  Component.onCompleted: {
    headersEditor.load({})
    authEditor.load("inherit")
    refreshGroups()
  }

  // --------------------------------------------------------------- groups

  function groupLabels() {
    var labels = ["None (ad-hoc)"]
    for (var i = 0; i < root.groups.length; i++) {
      var g = root.groups[i]
      var dup = root.groups.some(function (o) { return o !== g && o.name === g.name })
      labels.push(dup ? g.name + " (" + g.slug + ")" : g.name)
    }
    return labels
  }

  function groupLabel() {
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groups[i].path === root.groupPath) return root.groupLabels()[i + 1]
    }
    return "None (ad-hoc)"
  }

  function selectGroupByLabel(label) {
    var idx = root.groupLabels().indexOf(label)
    root.selectGroup(idx > 0 ? root.groups[idx - 1].path : "")
  }

  // env (optional) is applied once the file has loaded, else activeEnv is used.
  function selectGroup(path, env) {
    // Same file: FileView won't reload, so keep state instead of blanking it.
    if (path === root.groupPath) {
      var envs = root.group ? (root.group.environments || {}) : {}
      if (env && Object.keys(envs).indexOf(env) >= 0) root.envName = env
      return
    }
    root.currentRequestName = ""
    savedRequestsPanel.setName("")
    savedRequestsPanel.clearFilter()
    authEditor.load("inherit")
    root.pendingEnv = env || ""
    root.envName = ""
    root.groupPath = path
    if (path === "") {
      root.group = null
      if (root.view === "group") root.view = "request"
    }
  }

  function loadGroupText(text) {
    var g = Json.tryParse(text, null)
    if (!g || typeof g !== "object") { root.group = null; return }
    root.group = g
    var envs = Object.keys(g.environments || {})
    var want = root.pendingEnv || root.envName || g.activeEnv || ""
    root.pendingEnv = ""
    root.envName = envs.indexOf(want) >= 0 ? want : (envs.length > 0 ? envs[0] : "")
  }

  function saveGroup(g) {
    root.group = g
    groupFile.setText(JSON.stringify(g, null, 2) + "\n")
  }

  function setEnv(name) {
    root.envName = name
    if (!root.group) return
    var g = JSON.parse(JSON.stringify(root.group))
    g.activeEnv = name
    root.saveGroup(g)
  }

  function refreshGroups() {
    if (groupsListProc.running) { root.refreshPending = true; return }
    groupsListProc.command = [root.groupsBin, "list"]
    groupsListProc.running = true
  }

  function createGroup(name) {
    var n = String(name || "").trim()
    if (n === "" || groupsNewProc.running) return
    groupsNewProc.command = [root.groupsBin, "new", n]
    groupsNewProc.running = true
  }

  function slugOf(path) {
    return path.split("/").pop().replace(/\.json$/, "")
  }

  function importGroup(path) {
    var p = String(path || "").trim()
    if (p === "" || groupsImportProc.running) return
    root.importMessage = ""
    groupsImportProc.command = [root.groupsBin, "import", p]
    groupsImportProc.running = true
  }

  function exportGroup() {
    if (root.groupPath === "" || groupsExportProc.running) return
    root.importMessage = ""
    groupsExportProc.command = [root.groupsBin, "export", root.slugOf(root.groupPath)]
    groupsExportProc.running = true
  }

  // Generic confirm-before-destructive-action flow: askConfirm() shows the
  // dialog with a message and stashes the action; runConfirm() (wired to
  // ConfirmDialog.onConfirmed) fires it. Any destructive action in the
  // panel (delete group, delete saved request, clear history, ...) can
  // reuse this instead of hand-rolling its own pending-state property.
  function askConfirm(message, callback) {
    root.confirmMessage = message
    root.confirmCallback = callback
    root.confirmOpen = true
  }

  function closeConfirm() {
    root.confirmOpen = false
    root.confirmCallback = null
  }

  function runConfirm() {
    var cb = root.confirmCallback
    root.closeConfirm()
    if (cb) cb()
  }

  // Shared by every group/curl process's onExited: report success or failure
  // via importMessage instead of each handler setting the pair by hand.
  function setImportMessage(text, isError) {
    root.importMessage = text
    root.importMessageIsError = !!isError
  }

  // `result.error` when the process reported one, else `fallback`.
  function procError(result, fallback) {
    return (result && result.error) ? result.error : fallback
  }

  function askDeleteGroup() {
    if (root.groupPath === "" || !root.group) return
    var slug = root.slugOf(root.groupPath)
    root.askConfirm("Delete group \"" + (root.group.name || slug) + "\"? This cannot be undone.", function () {
      if (slug === "" || groupsDeleteProc.running) return
      groupsDeleteProc.command = [root.groupsBin, "delete", slug]
      groupsDeleteProc.running = true
    })
  }

  // Dropdown.value self-assigns on user interaction, which breaks a declarative
  // binding — so programmatic changes are pushed in imperatively.
  onGroupPathChanged: groupDropdown.value = root.groupLabel()
  onGroupChanged: if (root.group === null) {
    if (root.reqTab === "auth") root.reqTab = "headers"
    if (root.view === "group") root.view = "request"
  }
  onGroupsChanged: groupDropdown.value = root.groupLabel()
  onEnvNameChanged: envDropdown.value = root.envName
  onOpenedChanged: {
    if (root.opened) root.refreshGroups()
    else root.closeConfirm()
  }

  FileView {
    id: groupFile
    path: root.groupPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadGroupText(text())
    onLoadFailed: root.group = null
    onFileChanged: reload()
  }

  Process {
    id: groupsListProc
    stdout: StdioCollector { id: groupsListOut; waitForEnd: true }
    onExited: {
      var list = Json.tryParse(String(groupsListOut.text || "[]"), null)
      if (!Array.isArray(list)) list = null
      // A stale run may predate a just-created group; rerun before judging.
      if (root.refreshPending) {
        root.refreshPending = false
        if (list) root.groups = list
        root.refreshGroups()
        return
      }
      if (!list) return
      root.groups = list
      // Deleted out from under us: fall back to ad-hoc.
      if (root.groupPath !== "" && !root.groups.some(function (g) { return g.path === root.groupPath })) {
        root.selectGroup("")
      }
    }
  }

  Process {
    id: groupsNewProc
    stdout: StdioCollector { id: groupsNewOut; waitForEnd: true }
    onExited: {
      var made = Json.tryParse(String(groupsNewOut.text || "").trim(), null)
      root.creatingGroup = false
      if (!made || !made.path) return
      root.refreshGroups()
      root.selectGroup(made.path)
    }
  }

  Process {
    id: groupsImportProc
    stdout: StdioCollector { id: groupsImportOut; waitForEnd: true }
    onExited: {
      var made = Json.tryParse(String(groupsImportOut.text || "").trim(), null)
      if (!made || !made.path) {
        root.setImportMessage(root.procError(made, "import failed — check the file path"), true)
        return
      }
      root.importingGroup = false
      importPathField.text = ""
      root.refreshGroups()
      root.selectGroup(made.path)
      var warnings = made.warnings || []
      root.setImportMessage("Imported " + made.requestCount + " request(s) as \"" + made.name + "\""
        + (warnings.length > 0 ? " — " + warnings.length + " warning(s): " + warnings.join("; ") : ""), false)
    }
  }

  Process {
    id: groupsExportProc
    stdout: StdioCollector { id: groupsExportOut; waitForEnd: true }
    onExited: {
      var text = String(groupsExportOut.text || "").trim()
      var made = Json.tryParse(text, null)
      if (!made || !made.info) {
        root.setImportMessage(root.procError(made, "export failed"), true)
        return
      }
      if (!root.copyText(text)) {
        root.setImportMessage("another copy is still in progress — try again", true)
        return
      }
      root.setImportMessage("Copied Postman collection to clipboard", false)
    }
  }

  Process {
    id: groupsDeleteProc
    stdout: StdioCollector { id: groupsDeleteOut; waitForEnd: true }
    onExited: {
      var made = Json.tryParse(String(groupsDeleteOut.text || "").trim(), null)
      if (!made || !made.deleted) {
        root.setImportMessage(root.procError(made, "delete failed"), true)
        return
      }
      root.setImportMessage("Group deleted.", false)
      // groupsListProc's onExited already falls back to ad-hoc if the
      // currently-selected group has vanished from the refreshed list.
      root.refreshGroups()
    }
  }

  // ------------------------------------------------------- saved requests

  function loadSavedRequest(r) {
    root.currentRequestName = r.name
    savedRequestsPanel.setName(r.name)
    root.applyRequestState({ method: r.method, url: r.path || r.url, headers: r.headers, body: r.body, auth: r.auth })
  }

  function saveRequestAs(name) {
    var n = String(name || "").trim()
    if (!root.group || n === "") return
    var req = Groups.buildRequest(n, { method: root.method, url: root.url, headers: headersEditor.current(), body: root.body, auth: root.reqAuth })
    root.saveGroup(Groups.upsertRequest(root.group, req))
    root.currentRequestName = n
    savedRequestsPanel.setName(n)
  }

  // Save (as opposed to Save as): re-save the currently loaded request in
  // place. If the name field was edited, this renames it — the old entry
  // is dropped instead of left behind as a duplicate.
  function saveCurrentRequest() {
    if (root.currentRequestName === "") return
    var oldName = root.currentRequestName
    var n = savedRequestsPanel.name.trim()
    if (n === "") n = oldName
    var req = Groups.buildRequest(n, { method: root.method, url: root.url, headers: headersEditor.current(), body: root.body, auth: root.reqAuth })
    var g = Groups.upsertRequest(root.group, req)
    if (n !== oldName) g = Groups.removeRequest(g, oldName)
    root.saveGroup(g)
    root.currentRequestName = n
    savedRequestsPanel.setName(n)
  }

  function deleteSavedRequest(name) {
    if (!root.group) return
    root.saveGroup(Groups.removeRequest(root.group, name))
    if (root.currentRequestName === name) root.currentRequestName = ""
  }

  function askDeleteSavedRequest(name) {
    root.askConfirm("Delete saved request \"" + name + "\"? This cannot be undone.", function () {
      root.deleteSavedRequest(name)
    })
  }

  // -------------------------------------------------------------- sending

  function canSend() {
    return root.url.trim() !== "" && !root.sending
  }

  // The {method,headers,body,timeoutSec,...} sent to http-send/http-curl:
  // group requests resolve against groupFile/env/path/auth, ad-hoc ones
  // carry a plain url. Shared by send() and copyAsCurl() so the two stay
  // in sync on what a request actually consists of.
  function buildRequestPayload(trimmedUrl, headers) {
    var payload = { method: root.method, headers: headers, body: root.body, timeoutSec: root.timeoutSec }
    if (root.group) {
      payload.groupFile = root.groupPath
      payload.env = root.envName
      payload.path = trimmedUrl
      payload.auth = root.reqAuth
    } else {
      payload.url = trimmedUrl
    }
    return payload
  }

  function send() {
    if (!canSend()) return
    if (root.groupPath !== "" && !root.group) {
      root.response = { ok: false, status: 0, statusText: "", timeMs: 0, sizeBytes: 0,
        headers: {}, body: "", truncated: false, error: "group file could not be read" }
      return
    }
    var trimmedUrl = root.url.trim()
    root.url = trimmedUrl
    root.sendSeq++
    root.sending = true
    root.response = null
    var headers = headersEditor.current()
    root.pendingRequest = {
      method: root.method,
      url: trimmedUrl,
      headers: headers,
      body: root.body,
      group: root.group ? root.slugOf(root.groupPath) : "",
      groupPath: root.group ? root.groupPath : "",
      env: root.group ? root.envName : ""
    }
    var payload = root.buildRequestPayload(trimmedUrl, headers)
    // Resending an identical request would write byte-identical file content;
    // a changing nonce guarantees FileView sees a real write and fires onSaved.
    payload.nonce = Date.now() + "-" + Math.random().toString(36).slice(2, 8)
    requestFile.setText(JSON.stringify(payload))
  }

  // Abandon the in-flight request (user cancel, or the watchdog below). Bumping
  // sendSeq makes onExited/onSaved for the abandoned run no-ops; http-send takes
  // its curl child down on TERM.
  function cancelSend(message) {
    if (!root.sending) return
    root.sendSeq++
    root.sending = false
    root.startPending = false
    root.pendingRequest = null
    root.response = { ok: false, cancelled: true, status: 0, statusText: "", timeMs: 0, sizeBytes: 0,
      headers: {}, body: "", truncated: false, error: message }
    if (sendProc.running) sendProc.running = false
  }

  // A cancelled run may still be exiting when the next send is ready to start;
  // setting running = true on it would be a no-op, so wait for its onExited.
  function startSend() {
    if (sendProc.running) { root.startPending = true; return }
    sendProc.seq = root.sendSeq
    sendProc.command = [root.scriptDir + "/http-send", requestFile.path]
    sendProc.running = true
  }

  function formatBytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return v + " B"
    if (v < 1024 * 1024) return (v / 1024).toFixed(1) + " KB"
    return (v / (1024 * 1024)).toFixed(1) + " MB"
  }

  readonly property string heroMeta: {
    if (root.sending) return "Sending…"
    if (!root.response) return "No request sent yet"
    if (root.response.cancelled) return "Cancelled"
    if (root.response.error !== "") return "Error — " + root.response.error
    var line = root.response.status + " " + root.response.statusText
      + "  ·  " + root.response.timeMs + " ms  ·  " + root.formatBytes(root.response.sizeBytes)
    if (root.response.truncated) line += "  ·  truncated"
    return line
  }

  readonly property color heroColor: {
    if (!root.response || root.response.error !== "") return root.foreground
    if (root.response.status >= 200 && root.response.status < 400) return root.foreground
    return Color.urgent
  }

  FileView {
    id: requestFile
    path: root.requestPath
    printErrors: false
    onSaved: {
      if (root.sending) root.startSend()
    }
    onSaveFailed: {
      root.sending = false
      root.response = { ok: false, status: 0, statusText: "", timeMs: 0, sizeBytes: 0,
        headers: {}, body: "", truncated: false, error: "failed to write request file" }
    }
  }

  Process {
    id: sendProc
    property int seq: -1   // the sendSeq this run was started for
    stdout: StdioCollector { id: sendOut; waitForEnd: true }
    stderr: StdioCollector { id: sendErr; waitForEnd: true }
    onExited: function (code) {
      if (root.startPending) {
        root.startPending = false
        // Deferred a turn: `running` may still read true while inside onExited.
        if (root.sending) Qt.callLater(root.startSend)
        return
      }
      if (sendProc.seq !== root.sendSeq || !root.sending) return   // cancelled or superseded
      root.sending = false
      var parsed = Json.tryParse(String(sendOut.text || "").trim(), null)
      if (!parsed) {
        parsed = { ok: false, status: 0, statusText: "", timeMs: 0, sizeBytes: 0, headers: {}, body: "",
          truncated: false, error: String(sendErr.text || "").trim() || "http-send failed" }
      }
      root.response = parsed
      root.addHistoryEntry(root.pendingRequest, parsed)
      root.pendingRequest = null
    }
  }

  FileView {
    id: curlRequestFile
    path: root.curlRequestPath
    printErrors: false
    onSaved: curlProc.running = true
    onSaveFailed: {
      root.curlCopying = false
      root.setImportMessage("failed to write curl request file", true)
    }
  }

  Process {
    id: curlProc
    stdout: StdioCollector { id: curlOut; waitForEnd: true }
    stderr: StdioCollector { id: curlErr; waitForEnd: true }
    onExited: function (code) {
      root.curlCopying = false
      var parsed = Json.tryParse(String(curlOut.text || "").trim(), null)
      if (!parsed || !parsed.ok) {
        root.setImportMessage(root.procError(parsed, String(curlErr.text || "").trim() || "failed to build curl command"), true)
        return
      }
      if (!root.copyText(parsed.curl)) {
        root.setImportMessage("another copy is still in progress — try again", true)
        return
      }
      root.setImportMessage("Copied curl command to clipboard", false)
    }
  }

  // Resolves the current request (group baseUrl/auth/{{vars}} included, same
  // as send()) into a curl command line and copies it to the clipboard,
  // without sending anything.
  function copyAsCurl() {
    if (!root.canSend() || root.curlCopying) return
    var trimmedUrl = root.url.trim()
    var payload = root.buildRequestPayload(trimmedUrl, headersEditor.current())
    root.curlCopying = true
    curlProc.command = [root.scriptDir + "/http-curl", curlRequestFile.path]
    curlRequestFile.setText(JSON.stringify(payload))
  }

  // Safety net: curl is bounded by timeoutSec, so "sending" that outlives it
  // (plus slack) means the request never actually ran. Reset instead of hanging.
  Timer {
    id: sendWatchdog
    interval: (root.timeoutSec + 15) * 1000
    running: root.sending
    repeat: false
    onTriggered: root.cancelSend("No response from http-send — the request was reset.")
  }

  // -------------------------------------------------------------- history

  function addHistoryEntry(req, resp) {
    if (!req) return
    var entry = {
      id: Date.now() + "-" + Math.random().toString(36).slice(2, 8),
      method: req.method, url: req.url, headers: req.headers, body: req.body,
      group: req.group, groupPath: req.groupPath, env: req.env,
      // What was actually sent (substituted URL/headers/body, auth masked).
      // Lets the entry still be replayed as a plain request if its group is
      // later deleted or renamed, when the group-relative fields above can
      // no longer be resolved on their own.
      resolved: resp.resolved || null,
      ts: Math.floor(Date.now() / 1000),
      status: resp.ok ? resp.status : 0,
      ok: resp.ok
    }
    root.history = History.insertEntry(root.history, entry, root.historyLimit)
    historyFile.setText(JSON.stringify(root.history, null, 2) + "\n")
  }

  function loadHistoryText(text) {
    var v = Json.tryParse(text || "[]", [])
    root.history = Array.isArray(v) ? History.dedupe(v) : []
  }

  function applyRequestState(s) {
    root.method = s.method || "GET"
    root.url = s.url || ""
    // Dropdown.value and TextField.text self-assign internally on user
    // interaction (Dropdown's selectCurrent(), TextField's own editing),
    // which permanently breaks a `value: root.method` / `text: root.url`
    // declarative binding the first time the user touches either control.
    // After that, only an imperative set here actually updates what's shown.
    methodDropdown.value = root.method
    urlField.text = root.url
    bodyArea.text = s.body || ""
    headersEditor.load(s.headers || {})
    authEditor.load(s.auth === undefined ? "inherit" : s.auth)
    root.view = "request"
  }

  function applyHistoryEntry(entry) {
    root.currentRequestName = ""
    savedRequestsPanel.setName("")
    var known = entry.groupPath && root.groups.some(function (g) { return g.path === entry.groupPath })
    // selectGroup handles the same-path case (applies env directly) and the
    // different-path case (env applied via pendingEnv once the file loads).
    if (known) root.selectGroup(entry.groupPath, entry.env)
    else if (root.groupPath !== "") root.selectGroup("")   // group gone, or entry was ad-hoc
    // If the group is gone, replayState swaps in the resolved snapshot (a
    // usable ad-hoc request) instead of the now-unresolvable relative fields.
    root.applyRequestState(History.replayState(entry, known))
  }

  function clearHistory() {
    root.history = []
    historyFile.setText("[]\n")
  }

  function askClearHistory() {
    if (root.history.length === 0) return
    root.askConfirm("Clear all " + root.history.length + " history entries? This cannot be undone.", function () {
      root.clearHistory()
    })
  }

  function relTime(epoch) {
    if (!epoch) return ""
    var secs = Math.max(0, Math.floor(Date.now() / 1000) - epoch)
    if (secs < 45) return "just now"
    if (secs < 3600) return Math.round(secs / 60) + "m ago"
    if (secs < 86400) return Math.round(secs / 3600) + "h ago"
    return Math.round(secs / 86400) + "d ago"
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadHistoryText(text())
    onLoadFailed: root.loadHistoryText("[]")
    onFileChanged: reload()
  }

  // wl-copy has to stay resident to serve the Wayland selection, so anything
  // handed to it in argv sits in a world-readable /proc/<pid>/cmdline for as
  // long as the clipboard holds that entry — minutes or hours, not the
  // milliseconds a curl or jq run lasts. Everything this panel copies can
  // carry a credential: the resolved curl command (an Authorization header,
  // by design), a group export (bearer tokens, basic-auth passwords, apiKey
  // values), or a response body that contains an issued token. So the text
  // goes in over stdin, which no other user can read. Dropping stdinEnabled
  // is the EOF wl-copy waits for before it takes ownership of the selection
  // and forks into the background.
  Process {
    id: copyProc
    property string pending: ""
    command: ["wl-copy", "--trim-newline"]
    onStarted: {
      copyProc.write(copyProc.pending)
      copyProc.pending = ""
      copyProc.stdinEnabled = false
    }
  }

  // Returns false when a previous copy is still in flight, so a caller reports
  // that instead of claiming a copy that never happened.
  function copyText(text) {
    if (copyProc.running) return false
    copyProc.pending = String(text)
    copyProc.stdinEnabled = true
    copyProc.running = true
    return true
  }

  // Panel's own manageIpc:true already registers open/close/show/hide/toggle
  // for ipcTarget — no need to redeclare an IpcHandler here.

  // ------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⇄"
    tooltipText: "OmaPostal"
    onPressed: function (b) { root.toggle() }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(bodyColumn.implicitHeight, Style.space(640))

    // The confirmation lives outside PanelKeyCatcher on purpose: the catcher
    // goes `blocked` while a question is open, so the unhandled key bubbles
    // out to here (the catcher's own parent) and the dialog answers it.
    Keys.onPressed: function (event) {
      if (!root.confirmOpen) return
      if (confirmDialog.handleKey(event)) event.accepted = true
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || bodyArea.activeFocus || headersEditor.focusCount > 0 || newGroupField.activeFocus || savedRequestsPanel.anyFocus || authEditor.focusCount > 0 || groupEditor.anyFocus > 0 || root.confirmOpen
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: bodyColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: bodyColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            title: "OmaPostal"
            meta: root.heroMeta
            metaOpacity: 1.0
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Text {
              text: "⇄"
              color: root.heroColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          PanelSeparator { foreground: root.foreground }

          ButtonGroup {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            options: root.group
              ? [ { value: "request", label: "Request" },
                  { value: "history", label: "History (" + root.history.length + ")" },
                  { value: "group", label: "Group" } ]
              : [ { value: "request", label: "Request" },
                  { value: "history", label: "History (" + root.history.length + ")" } ]
            value: root.view
            onChanged: function (v) {
              var enteringGroup = (v === "group" && root.view !== "group")
              root.view = v
              if (enteringGroup) groupEditor.load(root.group)
            }
          }

          // ============================================================ request
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.view === "request"

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Dropdown {
                id: groupDropdown
                width: parent.width - newGroupBtn.width - importGroupBtn.width
                  - (exportGroupBtn.visible ? exportGroupBtn.width + parent.spacing : 0)
                  - (deleteGroupBtn.visible ? deleteGroupBtn.width + parent.spacing : 0)
                  - parent.spacing * 2
                  - (envDropdown.visible ? envDropdown.width + parent.spacing : 0)
                showLabel: false
                options: root.groupLabels()
                value: root.groupLabel()
                foreground: root.foreground
                onChanged: function (v) { root.selectGroupByLabel(v) }
              }

              Dropdown {
                id: envDropdown
                width: Style.space(110)
                visible: root.group !== null && Object.keys(root.group.environments || {}).length > 0
                showLabel: false
                options: root.group ? Object.keys(root.group.environments || {}) : []
                value: root.envName
                foreground: root.foreground
                onChanged: function (v) { root.setEnv(v) }
              }

              PanelActionButton {
                id: newGroupBtn
                iconText: root.creatingGroup ? "✕" : "＋"
                tooltipText: root.creatingGroup ? "Cancel new group" : "New group"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.creatingGroup = !root.creatingGroup
                  if (root.creatingGroup) root.importMessage = ""
                }
              }

              PanelActionButton {
                id: importGroupBtn
                iconText: root.importingGroup ? "✕" : "⇩"
                tooltipText: root.importingGroup ? "Cancel import" : "Import a Postman collection"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.importingGroup = !root.importingGroup
                  if (root.importingGroup) root.importMessage = ""
                }
              }

              PanelActionButton {
                id: exportGroupBtn
                iconText: "⇧"
                tooltipText: "Export group as a Postman collection (copies JSON to clipboard)"
                visible: root.group !== null
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.exportGroup()
              }

              PanelActionButton {
                id: deleteGroupBtn
                iconText: "×"
                tooltipText: "Delete this group"
                visible: root.group !== null
                foreground: root.foreground
                hoverColor: Color.urgent
                fontFamily: root.fontFamily
                onClicked: root.askDeleteGroup()
              }
            }

            Text {
              width: parent.width
              visible: root.groupPath !== "" && root.group === null
              text: "Group file could not be read — check its JSON."
              color: Color.urgent
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.importingGroup

              TextField {
                id: importPathField
                width: parent.width - importBtn.width - parent.spacing
                height: Style.spacing.controlHeight
                placeholderText: "Path to a .postman_collection.json file"
                foreground: root.foreground
                font.pixelSize: Style.font.caption
                onAccepted: root.importGroup(text)
              }

              Button {
                id: importBtn
                text: "Import"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.importGroup(importPathField.text)
              }
            }

            Text {
              width: parent.width
              visible: root.importMessage !== ""
              text: root.importMessage
              color: root.importMessageIsError ? Color.urgent : Qt.darker(root.foreground, 1.2)
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.creatingGroup

              TextField {
                id: newGroupField
                width: parent.width - createGroupBtn.width - parent.spacing
                height: Style.spacing.controlHeight
                placeholderText: "New group name"
                foreground: root.foreground
                font.pixelSize: Style.font.caption
                onAccepted: { root.createGroup(text); text = "" }
              }

              Button {
                id: createGroupBtn
                text: "Create"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: { root.createGroup(newGroupField.text); newGroupField.text = "" }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Dropdown {
                id: methodDropdown
                width: Style.space(96)
                showLabel: false
                options: root.methodOptions
                value: root.method
                foreground: root.foreground
                onChanged: function (v) { root.method = v }
              }

              TextField {
                id: urlField
                width: parent.width - methodDropdown.width - sendButton.width - curlBtn.width - parent.spacing * 3
                height: Style.spacing.controlHeight
                text: root.url
                placeholderText: root.group ? "/path or https://…" : "https://api.example.com/…"
                foreground: root.foreground
                font.pixelSize: Style.font.caption
                onTextChanged: root.url = text
                onAccepted: root.send()
              }

              Button {
                id: sendButton
                text: root.sending ? "Cancel" : "Send"
                iconText: root.sending ? "⟳" : ""
                iconSpinning: root.sending
                bordered: true
                enabled: root.sending || root.canSend()
                opacity: enabled ? 1.0 : 0.5
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.sending ? root.cancelSend("Request cancelled.") : root.send()
              }

              PanelActionButton {
                id: curlBtn
                iconText: "⧉"
                tooltipText: "Copy as curl"
                enabled: root.canSend() && !root.curlCopying
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copyAsCurl()
              }
            }

            Text {
              width: parent.width
              visible: root.response !== null && root.response.resolved !== undefined
              text: root.response && root.response.resolved
                ? "→ " + root.response.resolved.method + " " + root.response.resolved.url : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }

            SavedRequestsPanel {
              id: savedRequestsPanel
              width: parent.width
              group: root.group
              currentRequestName: root.currentRequestName
              foreground: root.foreground
              fontFamily: root.fontFamily
              onLoadRequested: function (r) { root.loadSavedRequest(r) }
              onDeleteRequested: function (name) { root.askDeleteSavedRequest(name) }
              onSaveRequested: root.saveCurrentRequest()
              onSaveAsRequested: function (name) { root.saveRequestAs(name) }
            }

            ButtonGroup {
              width: parent.width
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              options: root.group
                ? [ { value: "headers", label: "Headers (" + headersEditor.count + ")" },
                    { value: "auth", label: "Auth" },
                    { value: "body", label: "Body" } ]
                : [ { value: "headers", label: "Headers (" + headersEditor.count + ")" },
                    { value: "body", label: "Body" } ]
              value: root.reqTab
              onChanged: function (v) { root.reqTab = v }
            }

            HeadersEditor {
              id: headersEditor
              width: parent.width
              visible: root.reqTab === "headers"
              foreground: root.foreground
              fontFamily: root.fontFamily
              group: root.group
            }

            AuthEditor {
              id: authEditor
              width: parent.width
              visible: root.reqTab === "auth" && root.group !== null
              foreground: root.foreground
              fontFamily: root.fontFamily
              onEdited: function (a) { root.reqAuth = a }
            }

            // ---- body editor ----
            Item {
              width: parent.width
              height: Style.space(140)
              visible: root.reqTab === "body"

              BorderSurface {
                anchors.fill: parent
                color: Style.normalFill
                borderSpec: Border.controlSpec(bodyArea.activeFocus ? "focus" : "normal", root.foreground, Color.accent)
                radius: Style.cornerRadius

                ScrollView {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.sm
                  clip: true

                  TextArea {
                    id: bodyArea
                    placeholderText: "Request body (raw)"
                    wrapMode: TextArea.Wrap
                    color: root.foreground
                    placeholderTextColor: Qt.darker(root.foreground, 1.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    background: null
                    onTextChanged: root.body = text
                  }
                }
              }
            }

            ResponseViewer {
              width: parent.width
              response: root.response
              foreground: root.foreground
              fontFamily: root.fontFamily
              onCopyRequested: function (text) { root.copyText(text) }
            }
          }

          // ============================================================ history
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.view === "history"

            Text {
              width: parent.width
              visible: root.history.length === 0
              text: "No requests sent yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.history
              delegate: Button {
                required property var modelData
                width: parent.width
                leftAlign: true
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                text: (modelData.group ? "[" + modelData.group + (modelData.env ? "·" + modelData.env : "") + "]  " : "")
                  + modelData.method + "  " + modelData.url + "   ·   "
                  + (modelData.ok ? String(modelData.status) : "failed") + "   ·   " + root.relTime(modelData.ts)
                onClicked: root.applyHistoryEntry(modelData)
              }
            }

            Button {
              visible: root.history.length > 0
              text: "Clear history"
              leftAlign: true
              bordered: true
              foreground: Color.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.askClearHistory()
            }
          }

          // ============================================================= group
          GroupEditor {
            id: groupEditor
            width: parent.width
            visible: root.view === "group" && root.group !== null
            foreground: root.foreground
            fontFamily: root.fontFamily
            onSaved: function (g) {
              root.saveGroup(g)
              root.view = "request"
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      z: 10
      opened: root.confirmOpen
      message: root.confirmMessage
      confirmText: "Delete"
      background: Color.popups.background
      foreground: root.foreground
      fontFamily: root.fontFamily
      onCanceled: root.closeConfirm()
      onConfirmed: root.runConfirm()
    }
  }
}
