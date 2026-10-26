import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ruuts.studio-display"

  readonly property var service: bar?.shell?.serviceFor(root.moduleName)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.service = root.service
  }

  visible: root.service?.available === true
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onBarChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃠"
    tooltipText: root.service?.summary || ""
    dimmed: !root.service || (!root.service.autoBrightness && !root.service.trueTone) || root.service.manualPause
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
