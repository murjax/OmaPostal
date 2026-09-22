import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "lib/history.js" as History
import "lib/groups.js" as Groups

// Bar widget: a small Postman-style HTTP client.
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
  readonly property string requestPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/murjax-http-request.json"
  readonly property string curlRequestPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/murjax-http-curl-request.json"

  readonly property int timeoutSec: Math.max(5, parseInt(setting("timeoutSec", 30), 10) || 30)
  readonly property int historyLimit: Math.max(1, parseInt(setting("historyLimit", 20), 10) || 20)

  readonly property var methodOptions: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

  property string method: "GET"
  property string url: ""
  property string body: ""
  property string view: "request"    // "request" | "history"
  property string reqTab: "headers"  // "headers" | "auth" | "body"
  property string respTab: "body"    // "body" | "headers"

  property var reqAuth: "inherit"    // "inherit" | "none" | {type,...}; group mode only
  property int headerRev: 0
  readonly property var inheritedRows: {
    root.headerRev
    return root.group ? Groups.inheritedHeaders(root.group, root.headersObject()) : []
  }

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
  property string pendingDeleteSlug: ""

  readonly property color foreground: root.bar.foreground
  readonly property string fontFamily: root.bar.fontFamily
  readonly property color dim: Qt.darker(foreground, 1.4)

  // ------------------------------------------------------------- headers

  ListModel { id: headerModel }

  function resetHeaderRows(headers) {
    headerModel.clear()
    var h = headers || {}
    var keys = Object.keys(h)
    for (var i = 0; i < keys.length; i++) headerModel.append({ key: keys[i], value: String(h[keys[i]]) })
    if (headerModel.count === 0) headerModel.append({ key: "", value: "" })
    // A removed/replaced row can never fire its own activeFocusChanged(false),
    // so a structural change to the list is the safety net that untangles the
    // focus counter from a row that no longer exists.
    keyCatcher.headerFocusCount = 0
    root.headerRev++
  }

  function headersObject() {
    var out = {}
    for (var i = 0; i < headerModel.count; i++) {
      var row = headerModel.get(i)
      var k = String(row.key || "").trim()
      if (k === "") continue
      out[k] = String(row.value || "")
    }
    return out
  }

  Component.onCompleted: {
    resetHeaderRows({})
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
    saveNameField.text = ""
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
    var g = null
    try { g = JSON.parse(text) } catch (e) { g = null }
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

  function askDeleteGroup() {
    if (root.groupPath === "" || !root.group) return
    root.pendingDeleteSlug = root.slugOf(root.groupPath)
    root.confirmMessage = "Delete group \"" + (root.group.name || root.pendingDeleteSlug) + "\"? This cannot be undone."
    root.confirmOpen = true
  }

  function closeConfirm() {
    root.confirmOpen = false
    root.pendingDeleteSlug = ""
  }

  function confirmDeleteGroup() {
    var slug = root.pendingDeleteSlug
    root.closeConfirm()
    if (slug === "" || groupsDeleteProc.running) return
    groupsDeleteProc.command = [root.groupsBin, "delete", slug]
    groupsDeleteProc.running = true
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
      var list = null
      try { list = JSON.parse(String(groupsListOut.text || "[]")) } catch (e) { list = null }
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
      var made = null
      try { made = JSON.parse(String(groupsNewOut.text || "").trim()) } catch (e) { made = null }
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
      var made = null
      try { made = JSON.parse(String(groupsImportOut.text || "").trim()) } catch (e) { made = null }
      if (!made || !made.path) {
        var err = (made && made.error) ? made.error : "import failed — check the file path"
        root.importMessage = err
        root.importMessageIsError = true
        return
      }
      root.importingGroup = false
      importPathField.text = ""
      root.refreshGroups()
      root.selectGroup(made.path)
      var warnings = made.warnings || []
      root.importMessage = "Imported " + made.requestCount + " request(s) as \"" + made.name + "\""
        + (warnings.length > 0 ? " — " + warnings.length + " warning(s): " + warnings.join("; ") : "")
      root.importMessageIsError = false
    }
  }

  Process { id: exportCopyProc }

  Process {
    id: groupsExportProc
    stdout: StdioCollector { id: groupsExportOut; waitForEnd: true }
    onExited: {
      var text = String(groupsExportOut.text || "").trim()
      var made = null
      try { made = JSON.parse(text) } catch (e) { made = null }
      if (!made || !made.info) {
        root.importMessage = (made && made.error) ? made.error : "export failed"
        root.importMessageIsError = true
        return
      }
      exportCopyProc.command = ["wl-copy", "--trim-newline", text]
      exportCopyProc.running = true
      root.importMessage = "Copied Postman collection to clipboard"
      root.importMessageIsError = false
    }
  }

  Process {
    id: groupsDeleteProc
    stdout: StdioCollector { id: groupsDeleteOut; waitForEnd: true }
    onExited: {
      var made = null
      try { made = JSON.parse(String(groupsDeleteOut.text || "").trim()) } catch (e) { made = null }
      if (!made || !made.deleted) {
        root.importMessage = (made && made.error) ? made.error : "delete failed"
        root.importMessageIsError = true
        return
      }
      root.importMessage = "Group deleted."
      root.importMessageIsError = false
      // groupsListProc's onExited already falls back to ad-hoc if the
      // currently-selected group has vanished from the refreshed list.
      root.refreshGroups()
    }
  }

  // ------------------------------------------------------- saved requests

  function loadSavedRequest(r) {
    root.currentRequestName = r.name
    saveNameField.text = r.name
    root.applyRequestState({ method: r.method, url: r.path || r.url, headers: r.headers, body: r.body, auth: r.auth })
  }

  function saveRequestAs(name) {
    var n = String(name || "").trim()
    if (!root.group || n === "") return
    var req = Groups.buildRequest(n, { method: root.method, url: root.url, headers: root.headersObject(), body: root.body, auth: root.reqAuth })
    root.saveGroup(Groups.upsertRequest(root.group, req))
    root.currentRequestName = n
    saveNameField.text = n
  }

  // Save (as opposed to Save as): re-save the currently loaded request in
  // place. If the name field was edited, this renames it — the old entry
  // is dropped instead of left behind as a duplicate.
  function saveCurrentRequest() {
    if (root.currentRequestName === "") return
    var oldName = root.currentRequestName
    var n = saveNameField.text.trim()
    if (n === "") n = oldName
    var req = Groups.buildRequest(n, { method: root.method, url: root.url, headers: root.headersObject(), body: root.body, auth: root.reqAuth })
    var g = Groups.upsertRequest(root.group, req)
    if (n !== oldName) g = Groups.removeRequest(g, oldName)
    root.saveGroup(g)
    root.currentRequestName = n
    saveNameField.text = n
  }

  function deleteSavedRequest(name) {
    if (!root.group) return
    root.saveGroup(Groups.removeRequest(root.group, name))
    if (root.currentRequestName === name) root.currentRequestName = ""
  }

  // -------------------------------------------------------------- sending

  function canSend() {
    return root.url.trim() !== "" && !root.sending
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
    root.pendingRequest = {
      method: root.method,
      url: trimmedUrl,
      headers: root.headersObject(),
      body: root.body,
      group: root.group ? root.slugOf(root.groupPath) : "",
      groupPath: root.group ? root.groupPath : "",
      env: root.group ? root.envName : ""
    }
    var payload = {
      method: root.method,
      headers: root.pendingRequest.headers,
      body: root.body,
      timeoutSec: root.timeoutSec,
      // Resending an identical request would write byte-identical file content;
      // a changing nonce guarantees FileView sees a real write and fires onSaved.
      nonce: Date.now() + "-" + Math.random().toString(36).slice(2, 8)
    }
    if (root.group) {
      payload.groupFile = root.groupPath
      payload.env = root.envName
      payload.path = trimmedUrl
      payload.auth = root.reqAuth
    } else {
      payload.url = trimmedUrl
    }
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

  function prettyResponseBody() {
    if (!root.response) return ""
    var raw = String(root.response.body || "")
    try { return JSON.stringify(JSON.parse(raw), null, 2) } catch (e) { return raw }
  }

  function responseHeadersText() {
    if (!root.response) return ""
    var h = root.response.headers || {}
    return Object.keys(h).map(function (k) { return k + ": " + h[k] }).join("\n")
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
      var parsed = null
      try { parsed = JSON.parse(String(sendOut.text || "").trim()) } catch (e) { /* fall through */ }
      if (!parsed) {
        parsed = { ok: false, status: 0, statusText: "", timeMs: 0, sizeBytes: 0, headers: {}, body: "",
          truncated: false, error: String(sendErr.text || "").trim() || "http-send failed" }
      }
      root.response = parsed
      root.respTab = "body"
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
      root.importMessage = "failed to write curl request file"
      root.importMessageIsError = true
    }
  }

  Process {
    id: curlProc
    stdout: StdioCollector { id: curlOut; waitForEnd: true }
    stderr: StdioCollector { id: curlErr; waitForEnd: true }
    onExited: function (code) {
      root.curlCopying = false
      var parsed = null
      try { parsed = JSON.parse(String(curlOut.text || "").trim()) } catch (e) { /* fall through */ }
      if (!parsed || !parsed.ok) {
        root.importMessage = (parsed && parsed.error) ? parsed.error
          : (String(curlErr.text || "").trim() || "failed to build curl command")
        root.importMessageIsError = true
        return
      }
      root.copyText(parsed.curl)
      root.importMessage = "Copied curl command to clipboard"
      root.importMessageIsError = false
    }
  }

  // Resolves the current request (group baseUrl/auth/{{vars}} included, same
  // as send()) into a curl command line and copies it to the clipboard,
  // without sending anything.
  function copyAsCurl() {
    if (!root.canSend() || root.curlCopying) return
    var trimmedUrl = root.url.trim()
    var payload = { method: root.method, headers: root.headersObject(), body: root.body, timeoutSec: root.timeoutSec }
    if (root.group) {
      payload.groupFile = root.groupPath
      payload.env = root.envName
      payload.path = trimmedUrl
      payload.auth = root.reqAuth
    } else {
      payload.url = trimmedUrl
    }
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
    try {
      var v = JSON.parse(text || "[]")
      root.history = Array.isArray(v) ? History.dedupe(v) : []
    } catch (e) {
      root.history = []
    }
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
    root.resetHeaderRows(s.headers || {})
    authEditor.load(s.auth === undefined ? "inherit" : s.auth)
    root.view = "request"
  }

  function applyHistoryEntry(entry) {
    root.currentRequestName = ""
    saveNameField.text = ""
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

  Process { id: copyProc }

  function copyText(text) {
    if (copyProc.running) return
    copyProc.command = ["wl-copy", "--trim-newline", text]
    copyProc.running = true
  }

  function copyResponseArtifact() {
    if (!root.response) return
    root.copyText(root.respTab === "headers" ? root.responseHeadersText() : root.prettyResponseBody())
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
    tooltipText: "Omapostal"
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
      blocked: urlField.activeFocus || bodyArea.activeFocus || headerFocusCount > 0 || newGroupField.activeFocus || saveNameField.activeFocus || authEditor.focusCount > 0 || groupEditor.anyFocus > 0 || root.confirmOpen
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      property int headerFocusCount: 0

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
            title: "Omapostal"
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
                iconText: "＋"
                tooltipText: "New group"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.creatingGroup = !root.creatingGroup
              }

              PanelActionButton {
                id: importGroupBtn
                iconText: "⇩"
                tooltipText: "Import a Postman collection"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.importingGroup = !root.importingGroup
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

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.group !== null

              // Fixed-height mini-list: scrolls internally past ~5 rows
              // instead of stretching the whole (already-scrollable) panel.
              Item {
                width: parent.width
                height: Math.min(savedRequestsList.implicitHeight + Style.spacing.sm * 2, Style.space(200))
                visible: root.group !== null && (root.group.requests || []).length > 0

                BorderSurface {
                  anchors.fill: parent
                  color: Style.normalFill
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                  radius: Style.cornerRadius

                  ScrollView {
                    id: savedRequestsScroll
                    anchors.fill: parent
                    anchors.margins: Style.spacing.sm
                    clip: true

                    Column {
                      id: savedRequestsList
                      width: savedRequestsScroll.width
                      spacing: Style.spacing.sm

                      Repeater {
                        model: root.group ? (root.group.requests || []) : []
                        delegate: Row {
                          required property var modelData
                          width: parent.width
                          spacing: Style.spacing.sm

                          Button {
                            width: parent.width - delBtn.width - parent.spacing
                            leftAlign: true
                            bordered: true
                            selected: modelData.name === root.currentRequestName
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            fontSize: Style.font.caption
                            text: modelData.method + "  " + modelData.name
                            onClicked: root.loadSavedRequest(modelData)
                          }

                          PanelActionButton {
                            id: delBtn
                            iconText: "×"
                            tooltipText: "Delete saved request"
                            foreground: root.foreground
                            hoverColor: Color.urgent
                            fontFamily: root.fontFamily
                            onClicked: root.deleteSavedRequest(modelData.name)
                          }
                        }
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                TextField {
                  id: saveNameField
                  width: parent.width - saveBtn.width - saveAsBtn.width - parent.spacing * 2
                  height: Style.spacing.controlHeight
                  placeholderText: "Request name"
                  foreground: root.foreground
                  font.pixelSize: Style.font.caption
                  onAccepted: root.saveRequestAs(text)
                }

                Button {
                  id: saveBtn
                  text: "Save"
                  bordered: true
                  enabled: root.currentRequestName !== ""
                  opacity: enabled ? 1.0 : 0.5
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.saveCurrentRequest()
                }

                Button {
                  id: saveAsBtn
                  text: "Save as"
                  bordered: true
                  enabled: saveNameField.text.trim() !== ""
                  opacity: enabled ? 1.0 : 0.5
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.saveRequestAs(saveNameField.text)
                }
              }
            }

            ButtonGroup {
              width: parent.width
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              options: root.group
                ? [ { value: "headers", label: "Headers (" + headerModel.count + ")" },
                    { value: "auth", label: "Auth" },
                    { value: "body", label: "Body" } ]
                : [ { value: "headers", label: "Headers (" + headerModel.count + ")" },
                    { value: "body", label: "Body" } ]
              value: root.reqTab
              onChanged: function (v) { root.reqTab = v }
            }

            // ---- headers editor ----
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.reqTab === "headers"

              Repeater {
                model: root.inheritedRows
                delegate: Text {
                  required property var modelData
                  width: parent.width
                  text: modelData.key + ": " + modelData.value
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.strikeout: modelData.overridden
                  elide: Text.ElideRight
                }
              }

              Repeater {
                model: headerModel
                delegate: Row {
                  id: headerRow
                  required property int index
                  required property string key
                  required property string value
                  width: parent.width
                  spacing: Style.spacing.sm

                  TextField {
                    width: (parent.width - removeBtn.width - parent.spacing * 2) * 0.42
                    text: headerRow.key
                    placeholderText: "Header"
                    foreground: root.foreground
                    font.pixelSize: Style.font.caption
                    onTextChanged: { headerModel.setProperty(headerRow.index, "key", text); root.headerRev++ }
                    onActiveFocusChanged: keyCatcher.headerFocusCount += activeFocus ? 1 : -1
                  }

                  TextField {
                    width: (parent.width - removeBtn.width - parent.spacing * 2) * 0.58
                    text: headerRow.value
                    placeholderText: "Value"
                    foreground: root.foreground
                    font.pixelSize: Style.font.caption
                    onTextChanged: { headerModel.setProperty(headerRow.index, "value", text); root.headerRev++ }
                    onActiveFocusChanged: keyCatcher.headerFocusCount += activeFocus ? 1 : -1
                  }

                  PanelActionButton {
                    id: removeBtn
                    iconText: "×"
                    tooltipText: "Remove header"
                    foreground: root.foreground
                    hoverColor: Color.urgent
                    fontFamily: root.fontFamily
                    onClicked: {
                      headerModel.remove(headerRow.index)
                      keyCatcher.headerFocusCount = 0
                      root.headerRev++
                    }
                  }
                }
              }

              Button {
                text: "+ Add header"
                leftAlign: true
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: { headerModel.append({ key: "", value: "" }); root.headerRev++ }
              }
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

            // ---- response ----
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.response !== null

              PanelSeparator { foreground: root.foreground }

              Row {
                width: parent.width
                visible: root.response !== null && root.response.error === ""

                ButtonGroup {
                  width: parent.width - copyBtn.width
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  options: [
                    { value: "body", label: "Response body" },
                    { value: "headers", label: "Response headers (" + (root.response ? Object.keys(root.response.headers).length : 0) + ")" }
                  ]
                  value: root.respTab
                  onChanged: function (v) { root.respTab = v }
                }

                PanelActionButton {
                  id: copyBtn
                  iconText: "⧉"
                  tooltipText: root.respTab === "headers" ? "Copy response headers" : "Copy response body"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.copyResponseArtifact()
                }
              }

              Text {
                width: parent.width
                visible: root.response !== null && root.response.error !== ""
                text: root.response ? root.response.error : ""
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Item {
                width: parent.width
                height: Style.space(200)
                visible: root.response !== null && root.response.error === "" && root.respTab === "body"

                BorderSurface {
                  anchors.fill: parent
                  color: Style.normalFill
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                  radius: Style.cornerRadius

                  ScrollView {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.sm
                    clip: true

                    TextEdit {
                      readOnly: true
                      selectByMouse: true
                      wrapMode: TextEdit.Wrap
                      text: root.prettyResponseBody()
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xs
                visible: root.response !== null && root.response.error === "" && root.respTab === "headers"

                Repeater {
                  model: root.response ? Object.keys(root.response.headers) : []
                  delegate: Text {
                    required property string modelData
                    width: parent.width
                    text: modelData + ": " + root.response.headers[modelData]
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WrapAnywhere
                  }
                }
              }
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
              onClicked: root.clearHistory()
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
      onConfirmed: root.confirmDeleteGroup()
    }
  }
}
