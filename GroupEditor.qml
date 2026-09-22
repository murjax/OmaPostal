import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Edit a group's name, base URL, default headers, default auth and
// environments. Works on a private draft; emits saved(group) on Save.
Column {
  id: ge

  property color foreground
  property string fontFamily
  // Focus is derived from live fields, never counted: a counter can be
  // knocked out of sync by rows that are rebuilt or removed. Row fields
  // register in `focused` (by unique id) and unregister on destruction.
  property var focused: ({})
  property int uidSeq: 0
  // Panel blocks its key shortcuts while this is > 0.
  readonly property int anyFocus: (nameField.activeFocus ? 1 : 0) + (baseField.activeFocus ? 1 : 0)
    + (newEnvField.activeFocus ? 1 : 0) + Object.keys(ge.focused).length + authEditor.focusCount

  property var draft: ({})
  property string editEnv: ""     // environment whose variables are shown
  property int rev: 0             // bumped when the environment list changes

  signal saved(var group)

  spacing: Style.space(10)

  ListModel { id: headerRows }
  ListModel { id: varRows }

  function trackFocus(id, active) {
    var m = Object.assign({}, ge.focused)   // reassign so bindings re-evaluate
    if (active) m[id] = true
    else delete m[id]
    ge.focused = m
  }

  function fill(model, obj) {
    model.clear()
    Object.keys(obj || {}).forEach(function (k) { model.append({ key: k, value: String(obj[k]) }) })
    if (model.count === 0) model.append({ key: "", value: "" })
  }

  function toObject(model) {
    var out = {}
    for (var i = 0; i < model.count; i++) {
      var k = String(model.get(i).key || "").trim()
      if (k !== "") out[k] = String(model.get(i).value || "")
    }
    return out
  }

  function commitVars() {
    if (ge.editEnv === "") return
    ge.draft.environments = ge.draft.environments || {}
    ge.draft.environments[ge.editEnv] = ge.toObject(varRows)
  }

  function selectEnv(name) {
    ge.commitVars()
    ge.editEnv = name
    ge.fill(varRows, name !== "" ? ((ge.draft.environments || {})[name] || {}) : {})
    envDropdown.value = name
  }

  function addEnv(name) {
    var n = String(name || "").trim()
    if (n === "" || (ge.draft.environments || {})[n] !== undefined) return
    ge.commitVars()
    ge.draft.environments = ge.draft.environments || {}
    ge.draft.environments[n] = {}
    if (!ge.draft.activeEnv) ge.draft.activeEnv = n
    ge.rev++
    ge.selectEnv(n)
  }

  function deleteEnv() {
    if (ge.editEnv === "") return
    delete ge.draft.environments[ge.editEnv]
    var rest = Object.keys(ge.draft.environments)
    if (ge.draft.activeEnv === ge.editEnv) ge.draft.activeEnv = rest[0] || ""
    ge.editEnv = ""          // drop the deleted env's rows without committing them
    ge.rev++
    ge.selectEnv(rest[0] || "")
  }

  function load(group) {
    ge.draft = JSON.parse(JSON.stringify(group || {}))
    ge.editEnv = ""
    nameField.text = ge.draft.name || ""
    baseField.text = ge.draft.baseUrl || ""
    ge.fill(headerRows, ge.draft.headers || {})
    authEditor.load(ge.draft.auth || "none")
    var envs = Object.keys(ge.draft.environments || {})
    ge.rev++
    ge.selectEnv(envs.indexOf(ge.draft.activeEnv) >= 0 ? ge.draft.activeEnv : (envs[0] || ""))
  }

  function save() {
    ge.commitVars()
    var g = JSON.parse(JSON.stringify(ge.draft))
    g.name = nameField.text.trim() || g.name
    g.baseUrl = baseField.text
    g.headers = ge.toObject(headerRows)
    var a = authEditor.current()
    g.auth = (typeof a === "string") ? { type: "none" } : a
    ge.saved(g)
  }

  component SectionLabel: Text {
    width: ge.width
    color: Qt.darker(ge.foreground, 1.4)
    font.family: ge.fontFamily
    font.pixelSize: Style.font.caption
  }

  component KeyValueRows: Column {
    id: kv
    property var model
    property string keyPlaceholder: "Key"
    property string valuePlaceholder: "Value"
    width: ge.width
    spacing: Style.spacing.sm

    Repeater {
      model: kv.model
      delegate: Row {
        id: rowItem
        required property int index
        required property string key
        required property string value
        property int uid: -1
        width: kv.width
        spacing: Style.spacing.sm
        Component.onCompleted: rowItem.uid = ge.uidSeq++
        Component.onDestruction: { ge.trackFocus(rowItem.uid + "k", false); ge.trackFocus(rowItem.uid + "v", false) }

        TextField {
          width: (parent.width - rmBtn.width - parent.spacing * 2) * 0.42
          text: rowItem.key
          placeholderText: kv.keyPlaceholder
          foreground: ge.foreground
          font.pixelSize: Style.font.caption
          onTextChanged: kv.model.setProperty(rowItem.index, "key", text)
          onActiveFocusChanged: ge.trackFocus(rowItem.uid + "k", activeFocus)
        }

        TextField {
          width: (parent.width - rmBtn.width - parent.spacing * 2) * 0.58
          text: rowItem.value
          placeholderText: kv.valuePlaceholder
          foreground: ge.foreground
          font.pixelSize: Style.font.caption
          onTextChanged: kv.model.setProperty(rowItem.index, "value", text)
          onActiveFocusChanged: ge.trackFocus(rowItem.uid + "v", activeFocus)
        }

        PanelActionButton {
          id: rmBtn
          iconText: "×"
          tooltipText: "Remove"
          foreground: ge.foreground
          hoverColor: Color.urgent
          fontFamily: ge.fontFamily
          onClicked: kv.model.remove(rowItem.index)
        }
      }
    }

    Button {
      text: "+ Add"
      leftAlign: true
      bordered: true
      foreground: ge.foreground
      fontFamily: ge.fontFamily
      fontSize: Style.font.caption
      onClicked: kv.model.append({ key: "", value: "" })
    }
  }

  SectionLabel { text: "Name" }
  TextField {
    id: nameField
    width: parent.width
    foreground: ge.foreground
    font.pixelSize: Style.font.caption
  }

  SectionLabel { text: "Base URL (supports {{vars}})" }
  TextField {
    id: baseField
    width: parent.width
    placeholderText: "{{host}}/v1"
    foreground: ge.foreground
    font.pixelSize: Style.font.caption
  }

  SectionLabel { text: "Default headers" }
  KeyValueRows { model: headerRows; keyPlaceholder: "Header"; valuePlaceholder: "Value" }

  SectionLabel { text: "Default auth" }
  AuthEditor {
    id: authEditor
    width: parent.width
    allowInherit: false
    foreground: ge.foreground
    fontFamily: ge.fontFamily
  }

  SectionLabel { text: "Environments" }
  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Dropdown {
      id: envDropdown
      width: parent.width - delEnvBtn.width - parent.spacing
      showLabel: false
      options: { ge.rev; return Object.keys(ge.draft.environments || {}) }
      value: ge.editEnv
      foreground: ge.foreground
      onChanged: function (v) { ge.selectEnv(v) }
    }

    PanelActionButton {
      id: delEnvBtn
      iconText: "×"
      tooltipText: "Delete this environment"
      foreground: ge.foreground
      hoverColor: Color.urgent
      fontFamily: ge.fontFamily
      onClicked: ge.deleteEnv()
    }
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    TextField {
      id: newEnvField
      width: parent.width - addEnvBtn.width - parent.spacing
      height: Style.spacing.controlHeight
      placeholderText: "New environment name"
      foreground: ge.foreground
      font.pixelSize: Style.font.caption
      onAccepted: { ge.addEnv(text); text = "" }
    }

    Button {
      id: addEnvBtn
      text: "Add"
      bordered: true
      foreground: ge.foreground
      fontFamily: ge.fontFamily
      fontSize: Style.font.caption
      onClicked: { ge.addEnv(newEnvField.text); newEnvField.text = "" }
    }
  }

  KeyValueRows {
    visible: ge.editEnv !== ""
    model: varRows
    keyPlaceholder: "Variable"
    valuePlaceholder: "Value"
  }

  Button {
    text: "Save group"
    bordered: true
    foreground: ge.foreground
    fontFamily: ge.fontFamily
    fontSize: Style.font.caption
    onClicked: ge.save()
  }
}
