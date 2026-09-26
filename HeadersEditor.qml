import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "lib/groups.js" as Groups

// Header key/value rows, plus a read-only overlay of headers inherited from
// the group's defaults (struck through when a row below overrides them).
// Use load() to set it from outside: the TextFields self-assign `text` on
// user edits, which permanently breaks a declarative binding.
Column {
  id: ed

  property color foreground
  property string fontFamily
  property var group: null     // group file, for the inherited-headers overlay
  readonly property int focusCount: rowsEditor.focusCount
  readonly property int count: rows.count

  spacing: Style.spacing.sm

  ListModel { id: rows }

  // ListModel edits don't retrigger a binding that reads it via get()/loop,
  // so inheritedRows depends on this counter instead.
  property int rev: 0
  readonly property var inheritedRows: {
    ed.rev
    return ed.group ? Groups.inheritedHeaders(ed.group, ed.current()) : []
  }

  function current() {
    var out = {}
    for (var i = 0; i < rows.count; i++) {
      var row = rows.get(i)
      var k = String(row.key || "").trim()
      if (k === "") continue
      out[k] = String(row.value || "")
    }
    return out
  }

  function load(headers) {
    rows.clear()
    var h = headers || {}
    var keys = Object.keys(h)
    for (var i = 0; i < keys.length; i++) rows.append({ key: keys[i], value: String(h[keys[i]]) })
    if (rows.count === 0) rows.append({ key: "", value: "" })
    ed.rev++
  }

  Repeater {
    model: ed.inheritedRows
    delegate: Text {
      required property var modelData
      width: parent.width
      text: modelData.key + ": " + modelData.value
      color: Qt.darker(ed.foreground, 1.4)
      font.family: ed.fontFamily
      font.pixelSize: Style.font.caption
      font.strikeout: modelData.overridden
      elide: Text.ElideRight
    }
  }

  KeyValueRows {
    id: rowsEditor
    width: ed.width
    model: rows
    keyPlaceholder: "Header"
    valuePlaceholder: "Value"
    addLabel: "+ Add header"
    removeTooltip: "Remove header"
    foreground: ed.foreground
    fontFamily: ed.fontFamily
    onEdited: ed.rev++
  }
}
