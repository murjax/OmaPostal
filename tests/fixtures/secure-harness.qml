// Harness for tests/test-panel-secure.sh.
//
// Reproduces the ordering Panel.qml uses around a credential-bearing FileView
// write — the same lib/secure.js gate, the same bin/http-secure invocation,
// started in the same event loop turn as the write — so the race the gate
// exists to close can be run for real instead of reasoned about.
//
// Quickshell refuses a JS import that escapes the shell root (the directory
// of the file passed to `qs -p`), so the test copies this file and the real
// lib/secure.js into one temporary directory and runs it from there.
//
// HARNESS_MODE:
//   gated    - http-secure is started and the write is gated (what Panel.qml does)
//   ungated  - the write goes straight to FileView (what it did before the fix)
//   Any mode works with a bin/ whose http-secure fails, which must refuse.
//
// Writes "<WROTE|REFUSED|SAVEFAILED|TIMEOUT>\n" plus the resulting modes to
// HARNESS_RESULT, then exits.
import Quickshell
import Quickshell.Io
import QtQuick
import "secure.js" as Secure

ShellRoot {
  Item {
    id: root
    readonly property string dir: Quickshell.env("HARNESS_DIR")
    readonly property string requestPath: root.dir + "/request.json"
    readonly property string bin: Quickshell.env("HARNESS_BIN")
    readonly property string mode: Quickshell.env("HARNESS_MODE")
    readonly property string resultPath: Quickshell.env("HARNESS_RESULT")
    property var secureGate: Secure.create()

    Process {
      id: secureProc
      command: [root.bin + "/http-secure", "init", root.dir, root.requestPath]
      stdout: StdioCollector { id: secureOut; waitForEnd: true }
      onExited: function (code) {
        var queued = Secure.settle(root.secureGate, code === 0, "http-secure failed")
        for (var i = 0; i < queued.length; i++) queued[i]()
      }
    }

    function secureFiles() {
      if (secureProc.running) return
      Secure.markRunning(root.secureGate)
      secureProc.running = true
    }

    // Panel.qml's send(), reduced to the gate and the write it guards.
    function send() {
      if (root.mode !== "ungated") {
        var gate = Secure.check(root.secureGate, root.send)
        if (gate === "wait") { root.secureFiles(); return }
        if (gate === "refuse") { root.report("REFUSED"); return }
      }
      requestFile.setText('{"headers":{"Authorization":"Bearer ' + Quickshell.env("HARNESS_SECRET") + '"}}\n')
    }

    FileView {
      id: requestFile
      path: root.requestPath
      printErrors: false
      onSaved: root.report("WROTE")
      onSaveFailed: root.report("SAVEFAILED")
    }

    function report(what) {
      reportProc.command = ["bash", "-c",
        'printf "%s\\n" "$1" >"$2"; stat -c "%n %a" "$3" "$4" >>"$2" 2>&1; exit 0',
        "harness", what, root.resultPath, root.dir, root.requestPath]
      reportProc.running = true
    }
    Process { id: reportProc; onExited: Qt.exit(0) }

    Component.onCompleted: {
      // The panel starts http-secure when it opens, and the user can hit Send
      // in that same turn. This is that race, with nothing in between.
      if (root.mode !== "ungated") root.secureFiles()
      root.send()
    }

    Timer { interval: 15000; running: true; onTriggered: root.report("TIMEOUT") }
  }
}
