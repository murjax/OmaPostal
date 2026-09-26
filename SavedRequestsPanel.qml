import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Saved-requests list for the current group: collapsible, filterable by
// name/method/path, with load/delete per row and a save/save-as row for the
// request currently loaded in the editor. Shows a hint instead of the list
// when no group is selected.
//
// Panel owns the actual save/load/delete logic (it needs the rest of the
// request editor's state); this only emits what the user asked for.
Column {
  id: sr

  property var group: null
  property string currentRequestName: ""
  property color foreground
  property string fontFamily

  property bool collapsed: false
  property string filter: ""
  readonly property alias name: saveNameField.text
  readonly property bool anyFocus: saveNameField.activeFocus || savedRequestsSearch.activeFocus
  readonly property color dim: Qt.darker(sr.foreground, 1.4)

  signal loadRequested(var request)
  signal deleteRequested(string name)
  signal saveRequested()
  signal saveAsRequested(string name)

  spacing: Style.spacing.sm

  function setName(n) {
    saveNameField.text = n
  }

  // Switching to a different group (or ad-hoc): the search field's `text:`
  // binding is permanently broken once the user's typed in it, same as
  // every other TextField here, so it needs the same imperative resync as
  // clearFilterBtn's own onClicked.
  function clearFilter() {
    sr.filter = ""
    savedRequestsSearch.text = ""
  }

  function filteredRequests() {
    var all = sr.group ? (sr.group.requests || []) : []
    var q = sr.filter.trim().toLowerCase()
    if (q === "") return all
    return all.filter(function (r) {
      return (r.name || "").toLowerCase().indexOf(q) !== -1
        || (r.method || "").toLowerCase().indexOf(q) !== -1
        || (r.path || r.url || "").toLowerCase().indexOf(q) !== -1
    })
  }

  // Expanding is almost always followed by typing a filter, so send focus
  // straight to the search field. Deferred a turn so the field is actually
  // visible (and focusable) by the time it lands.
  onCollapsedChanged: {
    if (!sr.collapsed) Qt.callLater(function () { savedRequestsSearch.forceActiveFocus() })
  }

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: sr.group !== null

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: sr.group !== null && (sr.group.requests || []).length > 0

      PanelActionButton {
        id: savedRequestsToggle
        iconText: sr.collapsed ? "▸" : "▾"
        tooltipText: sr.collapsed ? "Show saved requests" : "Hide saved requests"
        foreground: sr.foreground
        fontFamily: sr.fontFamily
        onClicked: sr.collapsed = !sr.collapsed
      }

      Text {
        text: {
          var total = sr.group ? (sr.group.requests || []).length : 0
          if (sr.filter.trim() === "") return "Saved requests (" + total + ")"
          return "Saved requests (" + sr.filteredRequests().length + " of " + total + ")"
        }
        color: sr.dim
        font.family: sr.fontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          id: savedRequestsLabelMouse
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          hoverEnabled: true
          onClicked: sr.collapsed = !sr.collapsed
        }

        PanelToolTip {
          visible: savedRequestsLabelMouse.containsMouse
          text: sr.collapsed ? "Show saved requests" : "Hide saved requests"
          fontFamily: sr.fontFamily
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: !sr.collapsed && sr.group !== null && (sr.group.requests || []).length > 0

      TextField {
        id: savedRequestsSearch
        width: parent.width - (clearFilterBtn.visible ? clearFilterBtn.width + parent.spacing : 0)
        height: Style.spacing.controlHeight
        placeholderText: "Filter saved requests..."
        foreground: sr.foreground
        font.pixelSize: Style.font.caption
        text: sr.filter
        onTextChanged: sr.filter = text
      }

      PanelActionButton {
        id: clearFilterBtn
        iconText: "×"
        tooltipText: "Clear filter"
        visible: sr.filter !== ""
        foreground: sr.foreground
        fontFamily: sr.fontFamily
        onClicked: sr.clearFilter()
      }
    }

    // Fixed-height mini-list: scrolls internally past ~5 rows instead of
    // stretching the whole (already-scrollable) panel.
    Item {
      width: parent.width
      height: Math.min(savedRequestsList.implicitHeight + Style.spacing.sm * 2, Style.space(200))
      visible: !sr.collapsed && sr.group !== null && (sr.group.requests || []).length > 0

      BorderSurface {
        anchors.fill: parent
        color: Style.normalFill
        borderSpec: Border.controlSpec("normal", sr.foreground, Color.accent)
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

            Text {
              width: parent.width
              visible: sr.filteredRequests().length === 0
              text: "No saved requests match \"" + sr.filter.trim() + "\"."
              color: sr.dim
              font.family: sr.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }

            Repeater {
              model: sr.filteredRequests()
              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.spacing.sm

                Button {
                  width: parent.width - delBtn.width - parent.spacing
                  leftAlign: true
                  bordered: true
                  selected: modelData.name === sr.currentRequestName
                  foreground: sr.foreground
                  fontFamily: sr.fontFamily
                  fontSize: Style.font.caption
                  text: modelData.method + "  " + modelData.name
                  tooltipText: modelData.path || modelData.url || ""
                  onClicked: sr.loadRequested(modelData)
                }

                PanelActionButton {
                  id: delBtn
                  iconText: "×"
                  tooltipText: "Delete saved request"
                  foreground: sr.foreground
                  hoverColor: Color.urgent
                  fontFamily: sr.fontFamily
                  onClicked: sr.deleteRequested(modelData.name)
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
        foreground: sr.foreground
        font.pixelSize: Style.font.caption
        onAccepted: sr.saveAsRequested(text)
      }

      Button {
        id: saveBtn
        text: "Save"
        bordered: true
        enabled: sr.currentRequestName !== ""
        opacity: enabled ? 1.0 : 0.5
        foreground: sr.foreground
        fontFamily: sr.fontFamily
        fontSize: Style.font.caption
        onClicked: sr.saveRequested()
      }

      Button {
        id: saveAsBtn
        text: "Save as"
        bordered: true
        enabled: saveNameField.text.trim() !== ""
        opacity: enabled ? 1.0 : 0.5
        foreground: sr.foreground
        fontFamily: sr.fontFamily
        fontSize: Style.font.caption
        onClicked: sr.saveAsRequested(saveNameField.text)
      }
    }
  }

  Text {
    width: parent.width
    visible: sr.group === null
    text: "Select or create a group above to save and reuse requests."
    color: sr.dim
    font.family: sr.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
