import QtQuick
import qs.Commons
import qs.Ui

// The plugin's panel, behind its bar icon.
Panel {
  id: root
  moduleName: "io.github.ruuts.studio-display"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  function open() {
    section.enterCursor(1)
    service?.refreshNow()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(hostWidget || root, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(section.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { section.moveCursor(dx, dy) }
      onActivateRequested: section.activateCursor()

      DisplaySection {
        id: section
        width: parent.width
        service: root.service
        foreground: root.barForeground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        hasCursor: true
      }
    }
  }
}
