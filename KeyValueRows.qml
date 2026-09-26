import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Editable list of key/value rows (headers, env vars, ...) backed by an
// external ListModel: a remove button per row, plus an "+ Add" button that
// appends a blank one. Callers read edits back off `model` (via key/value
// property changes) and can listen to `edited()` for a change notification.
//
// Focus is tracked by row id rather than counted: a plain counter can be
// knocked out of sync by a row that's rebuilt or removed without its own
// activeFocusChanged(false) ever firing.
Column {
  id: kv

  property var model
  property string keyPlaceholder: "Key"
  property string valuePlaceholder: "Value"
  property string addLabel: "+ Add"
  property string removeTooltip: "Remove"
  property color foreground
  property string fontFamily

  property var focused: ({})
  property int uidSeq: 0
  readonly property int focusCount: Object.keys(kv.focused).length

  signal edited()

  spacing: Style.spacing.sm

  function trackFocus(id, active) {
    var m = Object.assign({}, kv.focused)   // reassign so bindings re-evaluate
    if (active) m[id] = true
    else delete m[id]
    kv.focused = m
  }

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
      Component.onCompleted: rowItem.uid = kv.uidSeq++
      Component.onDestruction: { kv.trackFocus(rowItem.uid + "k", false); kv.trackFocus(rowItem.uid + "v", false) }

      TextField {
        width: (parent.width - rmBtn.width - parent.spacing * 2) * 0.42
        text: rowItem.key
        placeholderText: kv.keyPlaceholder
        foreground: kv.foreground
        font.pixelSize: Style.font.caption
        onTextChanged: { kv.model.setProperty(rowItem.index, "key", text); kv.edited() }
        onActiveFocusChanged: kv.trackFocus(rowItem.uid + "k", activeFocus)
      }

      TextField {
        width: (parent.width - rmBtn.width - parent.spacing * 2) * 0.58
        text: rowItem.value
        placeholderText: kv.valuePlaceholder
        foreground: kv.foreground
        font.pixelSize: Style.font.caption
        onTextChanged: { kv.model.setProperty(rowItem.index, "value", text); kv.edited() }
        onActiveFocusChanged: kv.trackFocus(rowItem.uid + "v", activeFocus)
      }

      PanelActionButton {
        id: rmBtn
        iconText: "×"
        tooltipText: kv.removeTooltip
        foreground: kv.foreground
        hoverColor: Color.urgent
        fontFamily: kv.fontFamily
        onClicked: { kv.model.remove(rowItem.index); kv.edited() }
      }
    }
  }

  Button {
    text: kv.addLabel
    leftAlign: true
    bordered: true
    foreground: kv.foreground
    fontFamily: kv.fontFamily
    fontSize: Style.font.caption
    onClicked: { kv.model.append({ key: "", value: "" }); kv.edited() }
  }
}
