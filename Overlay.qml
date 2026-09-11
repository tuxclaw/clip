import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Clip.js" as Clip

Item {
  id: root
  property var shell: null
  property var manifest: null
  property bool opened: false
  property string filterText: ""
  property string category: "All"
  property int selectedIndex: 0
  property var history: []
  property var pins: []
  property var rows: []
  property var clearTargets: []
  property string errorMessage: ""
  property string historyError: ""
  property string pinsError: ""
  property string pendingPayload: ""
  property bool reloadPending: false
  readonly property var activeRow: rows.length ? rows[Math.min(selectedIndex, rows.length - 1)] : null
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int gap: Style.spacing.md
  readonly property color foreground: Color.menu.text
  readonly property color selectedText: Color.menu.selectedText
  readonly property color selectedBackground: Color.menu.selectedBackground

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (_) { return "invalid" }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return "invalid"
    filterText = typeof payload.query === "string" ? payload.query : ""
    category = ["All", "Text", "Images", "Files", "Pins"].indexOf(payload.filter) >= 0 ? payload.filter : "All"
    selectedIndex = 0
    errorMessage = ""
    reloadState()
    rebuild(false)
    opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus(); pointerGate.reset() })
    return "ok"
  }
  function close() {
    confirmation.opened = false
    opened = false
    return "ok"
  }
  function toggle(payloadJson) { return opened ? close() : open(payloadJson) }
  function status() {
    return JSON.stringify({opened: opened, count: rows.length, filter: category,
      historyError: historyError, pinsError: pinsError, busy: storage.running})
  }
  function rebuild(preserve) {
    var identity = preserve && activeRow ? activeRow.identity : ""
    rows = Clip.rows(history, pins, category, filterText)
    var found = rows.findIndex(function(row) { return row.identity === identity })
    selectedIndex = found >= 0 ? found : Math.max(0, Math.min(selectedIndex, rows.length - 1))
    Qt.callLater(function() { resultList.positionViewAtIndex(selectedIndex, ListView.Contain) })
  }
  function filter(value, nextCategory) {
    filterText = value
    category = nextCategory
    selectedIndex = 0
    pointerGate.reset()
    rebuild(false)
  }
  function select(delta) {
    if (!rows.length) return
    pointerGate.reset()
    selectedIndex = (selectedIndex + delta + rows.length) % rows.length
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }
  function activate(mode) {
    if (!activeRow || storage.running || historyError) return
    var row = activeRow
    close()
    if (mode === "open") {
      Quickshell.execDetached(["omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
    } else if (row.entryType === "image") {
      var args = ["omarchy-clipboard-paste-file"]
      if (mode === "copy") args.push("--copy-only")
      Quickshell.execDetached(args.concat([row.mime, row.path]))
    } else {
      Quickshell.execDetached(["omarchy-clipboard-paste-text", mode === "copy" ? "--copy-only" : "--shift-insert", "--history-index", String(row.historyIndex)])
    }
  }
  function save(operation, payload) {
    if (storage.running || (operation === "pin" ? pinsError : historyError)) return
    errorMessage = ""
    pendingPayload = JSON.stringify(payload)
    storage.command = ["python3", decodeURIComponent(Qt.resolvedUrl("storage.py").toString().substring(7)), operation]
    storage.running = true
  }
  function pin() { if (activeRow) save("pin", {identity: activeRow.identity}) }
  function remove() { if (activeRow) save("delete", {identity: activeRow.identity}) }
  function requestClear() {
    if (!history.length || historyError || storage.running) return
    clearTargets = history.map(function(item) { return Clip.key(item.entry) })
    confirmation.selectedIndex = 1
    confirmation.opened = true
  }

  function reloadState() {
    if (stateDump.running || storage.running) { reloadPending = true; return }
    reloadPending = false
    stateDump.running = true
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: root.reloadState()
  }
  Process {
    id: stateDump
    command: ["python3", decodeURIComponent(Qt.resolvedUrl("storage.py").toString().substring(7)), "dump"]
    stdout: StdioCollector { id: stateOutput }
    stderr: StdioCollector { id: stateErrors }
    onExited: function(code) {
      try {
        if (code !== 0) throw new Error(stateErrors.text.trim() || "Could not read clipboard state")
        var values = JSON.parse(stateOutput.text)
        root.history = Clip.parse(JSON.stringify(values.history))
        root.pins = values.pins
        root.historyError = ""
        root.pinsError = ""
      } catch (error) {
        root.history = []
        root.pins = []
        root.historyError = String(error)
        root.pinsError = root.historyError
      }
      root.rebuild(true)
      if (root.reloadPending) Qt.callLater(root.reloadState)
    }
  }
  Process {
    id: storage
    stdinEnabled: true
    onStarted: { write(root.pendingPayload + "\n") }
    stderr: StdioCollector { id: storageErrors }
    onExited: function(code) {
      if (code !== 0) root.errorMessage = storageErrors.text.trim() || "Could not save changes"
      Qt.callLater(root.reloadState)
    }
  }
  PointerMoveGate { id: pointerGate; referenceItem: card }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusiveZone: 0
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-clip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(680), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (confirmation.opened) { confirmation.handleKey(event); event.accepted = true; return }
          if (event.key === Qt.Key_Escape) root.close()
          else if (event.key === Qt.Key_Up) root.select(-1)
          else if (event.key === Qt.Key_Down) root.select(1)
          else if (event.key === Qt.Key_PageUp) root.select(-6)
          else if (event.key === Qt.Key_PageDown) root.select(6)
          else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            var filters = ["All", "Text", "Images", "Files", "Pins"]
            var delta = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1
            root.filter(root.filterText, filters[(filters.indexOf(root.category) + delta + 5) % 5])
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) root.pin()
          else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClear()
            else root.remove()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(event.modifiers & Qt.AltModifier ? "open" : event.modifiers & Qt.ShiftModifier ? "copy" : "paste")
          } else if (Util.editsFilter(event, root.filterText)) root.filter(Util.editedFilter(event, root.filterText), root.category)
          else if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && event.text && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
            root.filter(root.filterText + event.text, root.category)
          else return
          event.accepted = true
        }
      }

      Column {
        id: layout
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: root.gap
        Row {
          width: parent.width
          height: Style.space(38)
          spacing: root.gap
          Text {
            text: "Clip"
            color: root.selectedText
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            width: parent.width - x - clearButton.width - root.gap
            textFormat: Text.PlainText
            text: root.filterText || "Type to search clipboard…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
          Rectangle {
            id: clearButton
            width: Style.space(106)
            height: Style.space(30)
            anchors.verticalCenter: parent.verticalCenter
            enabled: root.history.length > 0 && !root.historyError && !storage.running
            opacity: enabled ? 1 : 0.4
            radius: Style.cornerRadius
            color: "transparent"
            Text {
              anchors.centerIn: parent
              text: "Clear all"
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.requestClear() }
          }
        }
        Row {
          id: filterRow
          spacing: Style.space(6)
          height: Style.space(32)
          Repeater {
            model: ["All", "Text", "Images", "Files", "Pins"]
            delegate: Rectangle {
              required property string modelData
              width: filterLabel.implicitWidth + Style.space(24)
              height: filterRow.height
              radius: Style.cornerRadius
              color: root.category === modelData ? root.selectedBackground : "transparent"
              Text {
                id: filterLabel
                anchors.centerIn: parent
                text: parent.modelData
                color: root.category === parent.modelData ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.filter(root.filterText, parent.modelData) }
            }
          }
        }
        Item {
          width: parent.width
          height: Math.max(0, parent.height - Style.space(70) - footer.height - root.gap * 3)
          Row {
            anchors.fill: parent
            spacing: root.gap
            ListView {
              id: resultList
              width: (parent.width - root.gap) * 0.46
              height: parent.height
              model: root.rows
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds
              delegate: Rectangle {
                id: entryRow
                required property int index
                required property var modelData
                readonly property bool selected: index === root.selectedIndex
                width: ListView.view.width
                readonly property bool hasListPreview: !!entryRow.modelData.image || entryRow.modelData.chip === "image"
                readonly property string listPreviewSource: entryRow.modelData.image || entryRow.modelData.path || ""
                height: hasListPreview ? Style.space(82) : Style.space(70)
                radius: Style.cornerRadius
                color: selected ? root.selectedBackground : "transparent"
                Row {
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: entryRow.hasListPreview ? Style.space(10) : 0
                  Rectangle {
                    id: listThumbnail
                    width: entryRow.hasListPreview ? Style.space(62) : 0
                    height: Style.space(62)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: entryRow.hasListPreview
                    radius: Style.cornerRadius
                    color: Util.alpha(entryRow.selected ? root.selectedText : root.foreground, 0.08)
                    border.width: Style.normalBorderWidth
                    border.color: Util.alpha(entryRow.selected ? root.selectedText : root.foreground, 0.28)
                    clip: true
                    Image {
                      anchors.fill: parent
                      anchors.margins: Style.space(3)
                      source: entryRow.listPreviewSource ? Util.fileUrl(entryRow.listPreviewSource) : ""
                      sourceSize.width: Math.max(1, width * 2)
                      sourceSize.height: Math.max(1, height * 2)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      smooth: true
                    }
                  }
                  Column {
                    width: parent.width - listThumbnail.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: entryRow.modelData.title
                      color: entryRow.selected ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
                    }
                    Row {
                      width: parent.width
                      spacing: Style.space(8)
                      Rectangle {
                        width: chipLabel.implicitWidth + Style.space(12)
                        height: chipLabel.implicitHeight + Style.space(2)
                        radius: Style.cornerRadius
                        color: Util.alpha(entryRow.selected ? root.selectedText : root.foreground, 0.1)
                        Text {
                          id: chipLabel
                          anchors.centerIn: parent
                          text: entryRow.modelData.chip
                          color: entryRow.selected ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                      Text {
                        width: parent.width - x
                        text: (entryRow.modelData.pinned ? "◆  " : "") + entryRow.modelData.metadata
                        color: entryRow.selected ? root.selectedText : root.foreground
                        opacity: 0.65
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function(mouse) { if (pointerGate.moved(entryRow, mouse)) root.selectedIndex = entryRow.index }
                  onClicked: { root.selectedIndex = entryRow.index; keyCatcher.forceActiveFocus() }
                  onDoubleClicked: root.activate("paste")
                }
              }
            }
            Rectangle {
              width: parent.width - resultList.width - root.gap
              height: parent.height
              color: "transparent"
              clip: true
              Rectangle { width: Style.normalBorderWidth; height: parent.height; color: Util.alpha(Color.menu.border, 0.35) }
              Column {
                anchors.fill: parent
                anchors.leftMargin: root.gap
                spacing: root.gap
                Row {
                  width: parent.width
                  height: Style.space(30)
                  Text {
                    width: parent.width - pinButton.width
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.activeRow ? root.activeRow.chip.toUpperCase() : "PREVIEW"
                    color: root.selectedText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Rectangle {
                    id: pinButton
                    width: Style.space(106)
                    height: parent.height
                    visible: !!root.activeRow
                    radius: Style.cornerRadius
                    color: root.activeRow && root.activeRow.pinned ? root.selectedBackground : "transparent"
                    Text {
                      anchors.centerIn: parent
                      text: root.activeRow && root.activeRow.pinned ? "◆ Unpin" : "◇ Pin"
                      color: root.selectedText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pin() }
                  }
                }
                Item {
                  id: preview
                  width: parent.width
                  height: parent.height - Style.space(30) - detailLabel.height - root.gap * 2
                  Image {
                    id: previewImage
                    anchors.fill: parent
                    visible: !!root.activeRow && !!root.activeRow.image
                    source: root.activeRow && root.activeRow.image ? Util.fileUrl(root.activeRow.image) : ""
                    sourceSize.width: Math.max(1, width * 2)
                    sourceSize.height: Math.max(1, height * 2)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                  }
                  Flickable {
                    id: textScroll
                    anchors.fill: parent
                    visible: !!root.activeRow && !root.activeRow.image
                    contentWidth: width
                    contentHeight: previewText.implicitHeight + swatch.height + (swatch.visible ? root.gap : 0)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Rectangle {
                      id: swatch
                      width: parent.width
                      height: visible ? Style.space(100) : 0
                      visible: !!root.activeRow && root.activeRow.chip === "color"
                      color: visible ? root.activeRow.content.trim() : "transparent"
                      radius: Style.cornerRadius
                    }
                    Text {
                      id: previewText
                      y: swatch.height + (swatch.visible ? root.gap : 0)
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.activeRow ? root.activeRow.content.slice(0, 65536) : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WrapAnywhere
                    }
                  }
                  Text {
                    anchors.centerIn: parent
                    visible: previewImage.visible && previewImage.status === Image.Error
                    text: "Image unavailable"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
                Text {
                  id: detailLabel
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.activeRow ? root.activeRow.metadata + (root.activeRow.content.length > 65536 ? " · Preview limited to 64K" : "") : ""
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WrapAnywhere
                }
              }
            }
          }
          Text {
            anchors.centerIn: parent
            visible: root.rows.length === 0
            text: root.history.length === 0 ? "Clipboard is empty" : root.category === "Pins" && !root.filterText ? "Pin an entry with Ctrl+P" : "No matching entries"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }
        Text {
          id: footer
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorMessage || root.historyError || root.pinsError || (root.rows.length + " entries" + (storage.running ? " · Saving…" : "") + "   Enter paste · Shift+Enter copy · Alt+Enter open\nDel remove · Shift+Del clear · Ctrl+P pin · Tab filter · Esc close")
          color: root.foreground
          opacity: 0.65
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
      ConfirmDialog {
        id: confirmation
        anchors.fill: parent
        z: 20
        message: "Delete entire clipboard history?"
        confirmText: "Delete"
        background: Color.menu.background
        foreground: root.foreground
        scrim: Color.menu.scrim
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: root.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: { opened = false; keyCatcher.forceActiveFocus(); pointerGate.reset() }
        onConfirmed: { opened = false; root.save("clear", {identities: root.clearTargets}); keyCatcher.forceActiveFocus() }
      }
    }
  }
  onActiveRowChanged: textScroll.contentY = 0
}
