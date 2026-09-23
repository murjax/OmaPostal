import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Tabbed response body/headers viewer with copy-to-clipboard. The
// status/time/size summary line is shown elsewhere (Panel's hero header).
Column {
  id: viewer

  property var response: null
  property color foreground
  property string fontFamily
  property string tab: "body"   // "body" | "headers"

  signal copyRequested(string text)

  spacing: Style.spacing.sm
  visible: viewer.response !== null

  onResponseChanged: viewer.tab = "body"

  function prettyBody() {
    if (!viewer.response) return ""
    var raw = String(viewer.response.body || "")
    try { return JSON.stringify(JSON.parse(raw), null, 2) } catch (e) { return raw }
  }

  function headersText() {
    if (!viewer.response) return ""
    var h = viewer.response.headers || {}
    return Object.keys(h).map(function (k) { return k + ": " + h[k] }).join("\n")
  }

  PanelSeparator { foreground: viewer.foreground }

  Row {
    width: parent.width
    visible: viewer.response !== null && viewer.response.error === ""

    ButtonGroup {
      width: parent.width - copyBtn.width
      foreground: viewer.foreground
      fontFamily: viewer.fontFamily
      fontSize: Style.font.caption
      options: [
        { value: "body", label: "Response body" },
        { value: "headers", label: "Response headers (" + (viewer.response ? Object.keys(viewer.response.headers).length : 0) + ")" }
      ]
      value: viewer.tab
      onChanged: function (v) { viewer.tab = v }
    }

    PanelActionButton {
      id: copyBtn
      iconText: "⧉"
      tooltipText: viewer.tab === "headers" ? "Copy response headers" : "Copy response body"
      foreground: viewer.foreground
      fontFamily: viewer.fontFamily
      onClicked: viewer.copyRequested(viewer.tab === "headers" ? viewer.headersText() : viewer.prettyBody())
    }
  }

  Text {
    width: parent.width
    visible: viewer.response !== null && viewer.response.error !== ""
    text: viewer.response ? viewer.response.error : ""
    color: Color.urgent
    font.family: viewer.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Item {
    width: parent.width
    height: Style.space(200)
    visible: viewer.response !== null && viewer.response.error === "" && viewer.tab === "body"

    BorderSurface {
      anchors.fill: parent
      color: Style.normalFill
      borderSpec: Border.controlSpec("normal", viewer.foreground, Color.accent)
      radius: Style.cornerRadius

      ScrollView {
        anchors.fill: parent
        anchors.margins: Style.spacing.sm
        clip: true

        TextEdit {
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          text: viewer.prettyBody()
          color: viewer.foreground
          font.family: viewer.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.xs
    visible: viewer.response !== null && viewer.response.error === "" && viewer.tab === "headers"

    Repeater {
      model: viewer.response ? Object.keys(viewer.response.headers) : []
      delegate: Text {
        required property string modelData
        width: parent.width
        text: modelData + ": " + viewer.response.headers[modelData]
        color: viewer.foreground
        font.family: viewer.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAnywhere
      }
    }
  }
}
