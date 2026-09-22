import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Auth type + fields. Shape in/out matches the group file:
//   "inherit" | "none" | {type:"bearer",token} | {type:"basic",username,password}
//   | {type:"apiKey",name,value,in}
// Use load() to set it from outside: the TextFields self-assign `text` on user
// edits, which permanently breaks a declarative binding.
Column {
  id: ed

  property color foreground
  property string fontFamily
  property bool allowInherit: true
  property int focusCount: 0
  property string kind: "inherit"

  signal edited(var auth)

  spacing: Style.spacing.sm

  readonly property var kindLabels: ({ inherit: "Inherit", none: "None", bearer: "Bearer", basic: "Basic", apiKey: "API key" })

  function kindOptions() {
    var o = ["None", "Bearer", "Basic", "API key"]
    return ed.allowInherit ? ["Inherit"].concat(o) : o
  }

  function kindFromLabel(label) {
    for (var k in ed.kindLabels) if (ed.kindLabels[k] === label) return k
    return "none"
  }

  function current() {
    if (ed.kind === "inherit" || ed.kind === "none") return ed.kind
    if (ed.kind === "bearer") return { type: "bearer", token: tokenField.text }
    if (ed.kind === "basic") return { type: "basic", username: userField.text, password: passField.text }
    return { type: "apiKey", name: keyNameField.text, value: keyValueField.text, "in": keyInDropdown.value }
  }

  function load(a) {
    var k = ed.allowInherit ? "inherit" : "none"
    var o = {}
    if (a === "none") k = "none"
    else if (a !== undefined && a !== null && typeof a === "object") { k = a.type || "none"; o = a }
    // Unknown type from a hand-edited file: treat as none.
    if (ed.kindLabels[k] === undefined) k = "none"
    ed.kind = k
    kindDropdown.value = ed.kindLabels[k]
    // keyInDropdown before the text fields: their onTextChanged emits call current().
    keyInDropdown.value = o["in"] || "header"
    tokenField.text = o.token || ""
    userField.text = o.username || ""
    passField.text = o.password || ""
    keyNameField.text = o.name || ""
    keyValueField.text = o.value || ""
    // Nothing above emits when the texts are unchanged, so always report the result.
    ed.edited(ed.current())
  }

  Dropdown {
    id: kindDropdown
    width: parent.width
    showLabel: false
    options: ed.kindOptions()
    value: ed.kindLabels[ed.kind]
    foreground: ed.foreground
    onChanged: function (v) { ed.kind = ed.kindFromLabel(v); ed.edited(ed.current()) }
  }

  Text {
    width: parent.width
    visible: ed.kind === "inherit" || ed.kind === "none"
    text: ed.kind === "inherit" ? "Uses the group's default auth." : "No auth is added to this request."
    color: Qt.darker(ed.foreground, 1.4)
    font.family: ed.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  TextField {
    id: tokenField
    width: parent.width
    visible: ed.kind === "bearer"
    placeholderText: "Token (supports {{vars}})"
    foreground: ed.foreground
    font.pixelSize: Style.font.caption
    onTextChanged: ed.edited(ed.current())
    onActiveFocusChanged: ed.focusCount += activeFocus ? 1 : -1
  }

  TextField {
    id: userField
    width: parent.width
    visible: ed.kind === "basic"
    placeholderText: "Username"
    foreground: ed.foreground
    font.pixelSize: Style.font.caption
    onTextChanged: ed.edited(ed.current())
    onActiveFocusChanged: ed.focusCount += activeFocus ? 1 : -1
  }

  TextField {
    id: passField
    width: parent.width
    visible: ed.kind === "basic"
    placeholderText: "Password"
    foreground: ed.foreground
    font.pixelSize: Style.font.caption
    onTextChanged: ed.edited(ed.current())
    onActiveFocusChanged: ed.focusCount += activeFocus ? 1 : -1
  }

  TextField {
    id: keyNameField
    width: parent.width
    visible: ed.kind === "apiKey"
    placeholderText: "Key name (e.g. X-Api-Key)"
    foreground: ed.foreground
    font.pixelSize: Style.font.caption
    onTextChanged: ed.edited(ed.current())
    onActiveFocusChanged: ed.focusCount += activeFocus ? 1 : -1
  }

  TextField {
    id: keyValueField
    width: parent.width
    visible: ed.kind === "apiKey"
    placeholderText: "Value (supports {{vars}})"
    foreground: ed.foreground
    font.pixelSize: Style.font.caption
    onTextChanged: ed.edited(ed.current())
    onActiveFocusChanged: ed.focusCount += activeFocus ? 1 : -1
  }

  Dropdown {
    id: keyInDropdown
    width: parent.width
    visible: ed.kind === "apiKey"
    showLabel: false
    options: ["header", "query"]
    value: "header"
    foreground: ed.foreground
    onChanged: function (v) { ed.edited(ed.current()) }
  }
}
