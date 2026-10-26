import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The Studio Display controls in this plugin's panel: three toggles, the finer
// settings folded under them. Brightness itself stays with Omarchy's Display
// panel and the brightness keys.
Column {
  id: root

  property var service: null
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool hasCursor: false

  property bool expanded: false
  readonly property color dim: Qt.darker(root.foreground, 1.4)
  readonly property color accent: Commons.Color.accent
  readonly property color accentText: Commons.Color.popups.background
  readonly property bool scheduleOn: service?.schedule.enabled === true

  readonly property var toggles: [
    { key: "auto", glyph: "󰃡", label: "Auto-brightness" },
    { key: "night", glyph: "󰔎", label: "Night light" },
    { key: "tone", glyph: "󰖨", label: "True Tone" }
  ]
  readonly property var profiles: [
    { value: "dim", label: "Dim" },
    { value: "balanced", label: "Balanced" },
    { value: "bright", label: "Bright" }
  ]
  readonly property var strengths: [
    { value: "subtle", label: "Subtle" },
    { value: "normal", label: "Normal" },
    { value: "strong", label: "Strong" }
  ]

  // Rows for the keyboard cursor; on the toggle row, one of the three toggles.
  readonly property var rows: expanded
    ? ["toggles", "settings", "profile", "strength", "schedule", "start", "end"]
    : ["toggles", "settings"]
  property int cursor: 0
  property int toggleIndex: 0
  readonly property string cursorRow: hasCursor ? rows[Math.max(0, Math.min(cursor, rows.length - 1))] : ""

  // ---- keyboard ------------------------------------------------------------

  function moveCursor(dx, dy) {
    if (dy !== 0) {
      var next = cursor + dy
      if (next < 0 || next >= rows.length) return false
      cursor = next
      return true
    }
    if (!service) return true
    if (cursorRow === "toggles") toggleIndex = Math.max(0, Math.min(2, toggleIndex + dx))
    else if (cursorRow === "profile") service.setSetting("profile", cycle(profiles, service.profile, dx))
    else if (cursorRow === "strength") service.setSetting("strength", cycle(strengths, service.strength, dx))
    else if (cursorRow === "start" || cursorRow === "end") shiftSchedule(cursorRow, dx)
    return true
  }

  function enterCursor(dy) {
    cursor = dy < 0 ? rows.length - 1 : 0
  }

  function activateCursor() {
    if (!service) return
    if (cursorRow === "toggles") press(toggles[toggleIndex].key)
    else if (cursorRow === "settings") expanded = !expanded
    else if (cursorRow === "schedule") service.setSchedule({ enabled: !scheduleOn })
  }

  function hover(row, index) {
    var at = rows.indexOf(row)
    if (at < 0) return
    cursor = at
    if (index !== undefined) toggleIndex = index
  }

  // ---- actions -------------------------------------------------------------

  function cycle(options, current, delta) {
    var index = 0
    for (var i = 0; i < options.length; i++) if (options[i].value === current) index = i
    return options[Math.max(0, Math.min(options.length - 1, index + delta))].value
  }

  function press(key) {
    if (!service) return
    if (key === "auto") service.toggleAutoBrightness()
    else if (key === "night") service.toggleNightLight()
    else if (key === "tone") service.toggleTrueTone()
  }

  function shiftSchedule(which, direction) {
    if (!service) return
    var change = {}
    change[which] = Model.shiftTime(service.schedule[which], direction * 30)
    service.setSchedule(change)
  }

  function isOn(key) {
    if (!service) return false
    if (key === "auto") return service.autoBrightness
    if (key === "night") return service.nightLight
    return service.trueTone
  }

  // Enabled but waiting: paused after a manual change, or True Tone during night light.
  function isWaiting(key) {
    if (!service) return false
    if (key === "auto") return service.autoBrightness && service.manualPause
    if (key === "tone") return service.trueTone && service.nightLight
    return false
  }

  function stateText(key) {
    if (!service) return ""
    if (key === "auto") {
      if (!service.autoBrightness) return "Off"
      var level = service.applied !== null ? " · " + service.applied + "%" : ""
      return (service.manualPause ? "Paused" : "On") + level
    }
    if (key === "night") {
      var s = service.schedule
      if (service.nightLight) return s.enabled ? "On until " + s.end : "On"
      return s.enabled ? "Off until " + s.start : "Off"
    }
    if (!service.trueTone) return "Off"
    if (service.nightLight) return "Paused"
    return service.nightState.ownTemp ? "On · " + service.nightState.ownTemp + " K" : "On"
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(12)
  visible: service !== null && service.available === true

  // Refresh the night light state while shown and True Tone (which polls it) is off.
  Timer {
    interval: 2000
    repeat: true
    running: root.visible && root.QsWindow.window !== null && root.QsWindow.window.visible
      && root.service?.trueTone !== true
    triggeredOnStart: true
    onTriggered: root.service?.refreshNow()
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(header.implicitHeight, reading.implicitHeight)

    PanelSectionHeader {
      id: header
      text: "STUDIO DISPLAY"
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: reading
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: root.service && root.service.lux !== null
        ? Math.round(root.service.lux) + " lux · " + Math.round(root.service.ambientK || 0) + " K" : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  Text {
    visible: text !== ""
    width: parent.width
    text: root.service?.error || ""
    color: Commons.Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // The three toggles: a round button (square on a square theme), name, state.
  Row {
    width: parent.width

    Repeater {
      model: root.toggles

      Item {
        id: tile
        required property var modelData
        required property int index
        readonly property bool active: root.isOn(modelData.key)
        readonly property bool waiting: root.isWaiting(modelData.key)
        readonly property bool hasCursor: root.cursorRow === "toggles" && root.toggleIndex === index

        width: parent.width / 3
        height: tileColumn.implicitHeight

        Column {
          id: tileColumn
          width: parent.width
          spacing: Style.space(6)

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(46)
            height: width
            radius: Style.cornerRadius > 0 ? width / 2 : 0
            color: tile.active && !tile.waiting ? root.accent : Style.selectedFillFor(root.foreground, root.accent)
            border.width: tile.hasCursor || tile.waiting || mouse.containsMouse ? Math.max(1, Style.space(2)) : 0
            border.color: tile.waiting ? root.accent : root.foreground

            Text {
              anchors.centerIn: parent
              text: tile.modelData.glyph
              color: tile.active && !tile.waiting ? root.accentText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.icon * 1.5)
            }

            MouseArea {
              id: mouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.hover("toggles", tile.index)
              onClicked: root.press(tile.modelData.key)
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: tile.modelData.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.stateText(tile.modelData.key)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    CursorSurface {
      width: parent.width
      height: settingsLabel.implicitHeight + Style.space(10)
      hasCursor: root.cursorRow === "settings"
      foreground: root.foreground
      outline: true

      Text {
        id: settingsLabel
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Settings"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.expanded ? "󰅀" : "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      HoverHandler { onHoveredChanged: if (hovered) root.hover("settings") }
      TapHandler { onTapped: root.expanded = !root.expanded }
    }

    CursorSurface {
      visible: root.expanded
      width: parent.width
      height: profileGroup.implicitHeight + Style.space(8)
      hasCursor: root.cursorRow === "profile"
      foreground: root.foreground
      outline: true

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Brightness"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      ButtonGroup {
        id: profileGroup
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        options: root.profiles
        value: root.service?.profile || "balanced"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        enabled: root.service?.autoBrightness === true
        opacity: enabled ? 1 : 0.4
        cursorIndex: root.cursorRow === "profile"
          ? root.profiles.findIndex(o => o.value === root.service?.profile) : -1
        onChanged: function(v) { root.service?.setSetting("profile", v) }
      }
      HoverHandler { onHoveredChanged: if (hovered) root.hover("profile") }
    }

    CursorSurface {
      visible: root.expanded
      width: parent.width
      height: strengthGroup.implicitHeight + Style.space(8)
      hasCursor: root.cursorRow === "strength"
      foreground: root.foreground
      outline: true

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "True Tone"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      ButtonGroup {
        id: strengthGroup
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        options: root.strengths
        value: root.service?.strength || "normal"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        enabled: root.service?.trueTone === true
        opacity: enabled ? 1 : 0.4
        cursorIndex: root.cursorRow === "strength"
          ? root.strengths.findIndex(o => o.value === root.service?.strength) : -1
        onChanged: function(v) { root.service?.setSetting("strength", v) }
      }
      HoverHandler { onHoveredChanged: if (hovered) root.hover("strength") }
    }

    CursorSurface {
      visible: root.expanded
      width: parent.width
      height: scheduleSwitch.implicitHeight + Style.space(4)
      hasCursor: root.cursorRow === "schedule"
      foreground: root.foreground
      outline: true

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Night light every evening"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      ToggleSwitch {
        id: scheduleSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: root.scheduleOn
        foreground: root.foreground
        onToggled: root.service?.setSchedule({ enabled: !root.scheduleOn })
      }
      HoverHandler { onHoveredChanged: if (hovered) root.hover("schedule") }
    }

    Repeater {
      model: [{ row: "start", label: "From" }, { row: "end", label: "Until" }]

      CursorSurface {
        id: timeRow
        required property var modelData
        visible: root.expanded
        width: parent.width
        height: stepper.implicitHeight + Style.space(4)
        hasCursor: root.cursorRow === modelData.row
        foreground: root.foreground
        outline: true
        opacity: root.scheduleOn ? 1 : 0.4

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: timeRow.modelData.label
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Row {
          id: stepper
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          PanelActionButton {
            iconText: "−"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.shiftSchedule(timeRow.modelData.row, -1)
          }
          Text {
            width: Style.space(46)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: root.service?.schedule[timeRow.modelData.row] || "--"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: timeRow.hasCursor
          }
          PanelActionButton {
            iconText: "+"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.shiftSchedule(timeRow.modelData.row, 1)
          }
        }
        HoverHandler { onHoveredChanged: if (hovered) root.hover(timeRow.modelData.row) }
      }
    }
  }
}
