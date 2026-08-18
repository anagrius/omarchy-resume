import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Resume

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : (Quickshell.env("HOME") + "/.config/omarchy/plugins/anagrius.resume")
  readonly property string resumeBin: pluginDir + "/bin/resume"

  property bool opened: false
  property bool loading: false
  property string errorText: ""
  property string filterText: ""
  property string sourceFilter: ""
  property string cwdFilter: ""
  property string groupBy: "date"
  property int selectedIndex: 0
  property bool cursorActive: false
  property string previewText: ""
  property bool previewLoading: false
  property bool handoffOpen: false
  property int handoffIndex: 0
  property bool herdrAvailable: false
  property bool herdrRunning: false
  property bool herdrStatusReady: false
  property bool herdrPromptOpen: false
  property int herdrPromptIndex: 1
  property string pendingAction: ""
  property string pendingAgent: ""
  property string statusText: ""
  property bool forceRefresh: false
  property double nowMs: Date.now()

  property var payload: Resume.emptyPayload()
  property var sessions: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Math.max(Style.space(22), Style.font.bodySmall + Style.spacing.xs)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(680), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(52), Style.font.title + Style.font.bodySmall + Style.spacing.rowPaddingX * 2)

  function open(payloadJson) {
    var incoming = Resume.parseOpenPayload(payloadJson)
    root.opened = true
    root.filterText = incoming.query
    root.sourceFilter = incoming.source
    root.cwdFilter = incoming.cwd
    // Kick the scan before the rest of the overlay work so it overlaps layout.
    root.refresh(false)
    root.refreshHerdrStatus()
    root.selectedIndex = 0
    root.cursorActive = true
    root.previewText = ""
    root.errorText = ""
    root.handoffOpen = false
    root.handoffIndex = 0
    root.herdrStatusReady = false
    root.herdrPromptOpen = false
    root.herdrPromptIndex = 1
    root.pendingAction = ""
    root.pendingAgent = ""
    root.statusText = ""
    root.nowMs = Date.now()
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.herdrPromptOpen = false
    root.pendingAction = ""
    root.pendingAgent = ""
    listProc.running = false
    previewProc.running = false
    herdrStatusProc.running = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "anagrius.resume")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh(force) {
    root.loading = true
    root.errorText = ""
    root.forceRefresh = force === true
    if (listProc.running) {
      listProc.running = false
      Qt.callLater(function() {
        if (root.opened) listProc.running = true
      })
    } else {
      listProc.running = true
    }
  }

  function applyPayload(raw) {
    var data = Resume.parsePayload(raw)
    var sources = data.sources || []
    for (var i = 0; i < data.sessions.length; i++) {
      var session = data.sessions[i]
      session.mark = markFor(sources, session.source)
    }
    root.payload = data
    root.loading = false
    root.rebuildDisplay()
  }

  function markFor(sources, sourceId) {
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].id === sourceId) return String(sources[i].mark || "")
    }
    return Util.fileUrl(root.pluginDir + "/assets/" + sourceId + ".svg")
  }

  function startOfLocalDay(ms) {
    var date = new Date(Number(ms))
    date.setHours(0, 0, 0, 0)
    return date.getTime()
  }

  function dayLabel(ms) {
    var stamp = Number(ms)
    if (!isFinite(stamp) || stamp <= 0) return "Older"
    var day = root.startOfLocalDay(stamp)
    var today = root.startOfLocalDay(root.nowMs)
    if (day === today) return "Today"
    var yesterday = new Date(today)
    yesterday.setDate(yesterday.getDate() - 1)
    if (day === yesterday.getTime()) return "Yesterday"
    var date = new Date(stamp)
    var months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    var label = months[date.getMonth()] + " " + date.getDate()
    if (date.getFullYear() !== new Date(root.nowMs).getFullYear())
      label += ", " + date.getFullYear()
    return label
  }

  function rebuildDisplay() {
    var filtered = Resume.filterSessions(root.payload.sessions, root.filterText, root.sourceFilter)
    root.sessions = filtered

    displayModel.clear()

    var rows = []
    for (var i = 0; i < filtered.length; i++) {
      var flat = Resume.flattenSession(filtered[i], root.nowMs)
      rows.push({
        sessionId: flat.sessionId,
        source: flat.source,
        title: flat.title,
        cwd: flat.cwd,
        project: flat.project,
        projectKey: String(filtered[i].projectKey || flat.projectKey || flat.cwd),
        projectLabel: String(filtered[i].projectLabel || flat.projectLabel || flat.project || flat.cwd),
        modelName: flat.modelName,
        snippet: flat.snippet,
        messageCount: flat.messageCount,
        updatedAtMs: flat.updatedAtMs,
        updatedLabel: flat.updatedLabel,
        mark: String(filtered[i].mark || markFor(root.payload.sources, flat.source))
      })
    }

    if (root.groupBy === "project") {
      var latest = ({})
      for (var p = 0; p < rows.length; p++) {
        var pkey = rows[p].projectKey || rows[p].cwd
        if (!latest[pkey] || rows[p].updatedAtMs > latest[pkey]) latest[pkey] = rows[p].updatedAtMs
      }
      rows.sort(function(a, b) {
        var ak = a.projectKey || a.cwd
        var bk = b.projectKey || b.cwd
        if (latest[bk] !== latest[ak]) return latest[bk] - latest[ak]
        return b.updatedAtMs - a.updatedAtMs
      })
    }

    var lastGroup = ""
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r]
      var group = root.groupBy === "project"
        ? (row.projectLabel || row.project || row.cwd || "No folder")
        : root.dayLabel(row.updatedAtMs)
      displayModel.append({
        sessionId: row.sessionId,
        source: row.source,
        title: row.title,
        cwd: row.cwd,
        project: row.project,
        projectKey: row.projectKey,
        projectLabel: row.projectLabel,
        modelName: row.modelName,
        snippet: row.snippet,
        messageCount: row.messageCount,
        updatedAtMs: row.updatedAtMs,
        updatedLabel: row.updatedLabel,
        dayGroup: group,
        showDayHeader: group !== lastGroup,
        mark: row.mark
      })
      lastGroup = group
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      root.rebuildTargets()
      root.requestPreview()
    })
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function setGroupBy(mode) {
    if (mode !== "date" && mode !== "project") return
    if (root.groupBy === mode) return
    root.groupBy = mode
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.persistGroupBy()
    root.rebuildDisplay()
  }

  function toggleGroupBy() {
    root.setGroupBy(root.groupBy === "date" ? "project" : "date")
  }

  function persistGroupBy() {
    var current = {}
    try { current = JSON.parse(groupByFile.text() || "{}") } catch (e) { current = {} }
    if (!current || typeof current !== "object") current = {}
    current.groupBy = root.groupBy
    groupByFile.setText(JSON.stringify(current, null, 2) + "\n")
  }

  function loadGroupBy(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      if (data && (data.groupBy === "date" || data.groupBy === "project"))
        root.groupBy = data.groupBy
    } catch (e) {}
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
    root.rebuildTargets()
    root.requestPreview()
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    root.rebuildTargets()
    root.requestPreview()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    if (root.selectedIndex !== index) {
      root.selectedIndex = index
      root.requestPreview()
    }
  }

  function scrollPreview(direction) {
    var page = Math.max(Style.space(80), previewFlick.height - Style.space(24))
    var maxY = Math.max(0, previewFlick.contentHeight - previewFlick.height)
    previewFlick.contentY = Math.max(0, Math.min(maxY, previewFlick.contentY + direction * page))
  }

  function requestPreview() {
    previewProc.running = false
    if (displayModel.count === 0) {
      root.previewText = ""
      root.previewLoading = false
      return
    }
    root.previewLoading = true
    previewTimer.restart()
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    root.selectedIndex = index
    root.requestLaunch("resume", "")
  }

  function refreshHerdrStatus() {
    herdrStatusProc.running = false
    herdrStatusProc.running = true
  }

  function applyHerdrStatus(raw) {
    var data = Resume.parseHerdrStatus(raw)
    root.herdrAvailable = data.available
    root.herdrRunning = data.running
    root.herdrStatusReady = true
    if (root.opened && root.pendingAction && !root.herdrPromptOpen) {
      var action = root.pendingAction
      var agentId = root.pendingAgent
      root.pendingAction = ""
      root.pendingAgent = ""
      root.requestLaunch(action, agentId)
    }
  }

  function requestLaunch(action, agentId) {
    if (displayModel.count === 0) return
    if (!root.herdrStatusReady) {
      root.pendingAction = action
      root.pendingAgent = agentId || ""
      root.refreshHerdrStatus()
      return
    }
    if (root.herdrRunning) {
      root.commitLaunch(action, agentId, "herdr")
      return
    }
    if (root.herdrAvailable) {
      root.pendingAction = action
      root.pendingAgent = agentId || ""
      root.herdrPromptIndex = 1
      root.herdrPromptOpen = true
      root.handoffOpen = false
      root.disarmPointer()
      return
    }
    root.commitLaunch(action, agentId, "terminal")
  }

  function cancelHerdrPrompt() {
    root.herdrPromptOpen = false
    root.pendingAction = ""
    root.pendingAgent = ""
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmHerdrPrompt() {
    var target = root.herdrPromptIndex === 1 ? "herdr" : "terminal"
    var action = root.pendingAction || "resume"
    var agentId = root.pendingAgent
    root.herdrPromptOpen = false
    root.commitLaunch(action, agentId, target)
  }

  function commitLaunch(action, agentId, target) {
    var row = root.currentRow()
    if (!row) return
    var args = [root.resumeBin]
    if (action === "open") {
      if (!agentId) return
      args.push("open", row.source, row.sessionId, "--agent", agentId)
    } else {
      args.push("resume", row.source, row.sessionId)
    }
    args.push(target === "herdr" ? "--herdr" : "--terminal")
    root.dismiss()
    Quickshell.execDetached(args)
  }

  function copySession() {
    var row = root.currentRow()
    if (!row) return
    copyProc.running = false
    copyProc.running = true
  }

  function applyCopyResult(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (data && data.ok) {
        root.statusText = "Copied transcript"
        statusTimer.restart()
        return
      }
      root.statusText = (data && data.error) ? String(data.error) : "Copy failed"
    } catch (e) {
      root.statusText = "Copy failed"
    }
    statusTimer.restart()
  }

  function rebuildTargets() {
    targetModel.clear()
    var row = root.currentRow()
    var pack = Resume.handoffTargets(root.payload.sources || [], row ? row.source : "")
    for (var i = 0; i < pack.targets.length; i++) {
      var target = pack.targets[i]
      targetModel.append({
        targetId: target.id,
        targetName: target.name,
        mark: target.mark,
        isDefault: target.isDefault
      })
    }
    if (root.handoffIndex >= targetModel.count) root.handoffIndex = Math.max(0, targetModel.count - 1)
    else if (targetModel.count > 0 && !root.handoffOpen) root.handoffIndex = pack.preferred
  }

  function toggleHandoff() {
    if (displayModel.count === 0) return
    root.rebuildTargets()
    if (targetModel.count === 0) {
      root.statusText = "No other installed agent to open in"
      statusTimer.restart()
      return
    }
    root.handoffOpen = !root.handoffOpen
    root.disarmPointer()
  }

  function cycleHandoff(delta) {
    if (targetModel.count === 0) return
    root.handoffIndex = (root.handoffIndex + delta + targetModel.count) % targetModel.count
  }

  function openInCurrentTarget() {
    if (targetModel.count === 0) return
    var target = targetModel.get(Math.max(0, Math.min(root.handoffIndex, targetModel.count - 1)))
    root.openInAgent(target.targetId)
  }

  function openInAgent(agentId) {
    if (!agentId) return
    root.requestLaunch("open", agentId)
  }

  function currentRow() {
    if (displayModel.count === 0 || selectedIndex < 0 || selectedIndex >= displayModel.count)
      return null
    return displayModel.get(selectedIndex)
  }

  ListModel { id: displayModel }
  ListModel { id: targetModel }

  FileView {
    id: groupByFile
    path: Quickshell.env("HOME") + "/.config/omarchy/resume.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadGroupBy(text())
    onFileChanged: reload()
  }

  Timer {
    id: statusTimer
    interval: 1800
    repeat: false
    onTriggered: root.statusText = ""
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: listProc
    command: {
      var args = [root.resumeBin, "list", "--limit", "240"]
      if (root.forceRefresh) args.push("--refresh")
      if (root.cwdFilter) { args.push("--cwd"); args.push(root.cwdFilter) }
      return args
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text)
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0 && root.opened) {
        root.loading = false
        root.errorText = "Could not read sessions"
      }
    }
  }

  Timer {
    id: previewTimer
    interval: 70
    repeat: false
    onTriggered: {
      if (!root.opened || displayModel.count === 0) return
      previewProc.running = true
    }
  }

  Process {
    id: previewProc
    command: {
      var row = root.currentRow()
      if (!row) return ["true"]
      return [root.resumeBin, "preview", row.source, row.sessionId]
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.previewText = String(text || "")
        root.previewLoading = false
      }
    }
    onExited: function(code) {
      if (code !== 0) root.previewLoading = false
    }
  }

  Process {
    id: herdrStatusProc
    command: [root.resumeBin, "herdr-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHerdrStatus(text)
    }
  }

  Process {
    id: copyProc
    command: {
      var row = root.currentRow()
      if (!row) return ["true"]
      return [root.resumeBin, "copy", row.source, row.sessionId]
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCopyResult(text)
    }
    onExited: function(code) {
      if (code !== 0 && !root.statusText) {
        root.statusText = "Copy failed"
        statusTimer.restart()
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "anagrius-resume"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.herdrPromptOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.herdrPromptOpen) {
            if (herdrPrompt.handleKey(event)) event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) {
            if (root.handoffOpen) root.handoffOpen = false
            else if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            if (root.handoffOpen) root.cycleHandoff(event.modifiers & Qt.ShiftModifier ? -1 : 1)
            else root.toggleGroupBy()
            event.accepted = true
          } else if (event.key === Qt.Key_G && (event.modifiers & Qt.ControlModifier)) {
            root.toggleGroupBy()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
            root.refresh(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_P || event.key === Qt.Key_K)) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_N || event.key === Qt.Key_J)) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.scrollPreview(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.scrollPreview(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Y && (event.modifiers & Qt.ControlModifier)) {
            root.copySession()
            event.accepted = true
          } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
            root.copySession()
            event.accepted = true
          } else if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)) {
            root.toggleHandoff()
            event.accepted = true
          } else if (event.key === Qt.Key_Left && root.handoffOpen) {
            root.cycleHandoff(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right && root.handoffOpen) {
            root.cycleHandoff(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.handoffOpen) root.openInCurrentTarget()
            else if (event.modifiers & Qt.ShiftModifier) root.copySession()
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        Item {
          id: herdrPrompt
          anchors.fill: parent
          visible: root.herdrPromptOpen
          z: 10

          function handleKey(event) {
            if (!root.herdrPromptOpen) return false
            if (event.key === Qt.Key_Escape) {
              root.cancelHerdrPrompt()
              return true
            }
            if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.herdrPromptIndex = root.herdrPromptIndex === 0 ? 1 : 0
              return true
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.confirmHerdrPrompt()
              return true
            }
            if (event.key === Qt.Key_H) {
              root.herdrPromptIndex = 1
              root.confirmHerdrPrompt()
              return true
            }
            if (event.key === Qt.Key_T) {
              root.herdrPromptIndex = 0
              root.confirmHerdrPrompt()
              return true
            }
            return true
          }

          Rectangle {
            anchors.fill: parent
            color: root.scrim
            MouseArea { anchors.fill: parent; onClicked: root.cancelHerdrPrompt() }
          }

          BorderSurface {
            width: Math.min(parent.width - Style.space(32), Style.space(390))
            height: herdrPromptMessage.implicitHeight + Style.space(72)
            anchors.centerIn: parent
            color: root.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: root.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(4)
              spacing: Style.space(16)

              Text {
                id: herdrPromptMessage
                width: parent.width
                text: "Herdr is not running. Open this session in Herdr?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Item {
                width: parent.width
                height: Style.space(34)

                Row {
                  anchors.right: parent.right
                  spacing: Style.space(10)

                BorderSurface {
                  width: Style.space(96)
                  height: Style.space(34)
                  color: root.herdrPromptIndex === 0 ? root.selectedBackground : "transparent"
                  borderSpec: Border.flat(
                    root.herdrPromptIndex === 0 ? root.selectedText : Util.alpha(root.foreground, 0.38),
                    Style.normalBorderWidth)
                  radius: 0
                  Text {
                    anchors.centerIn: parent
                    text: "Terminal"
                    color: root.herdrPromptIndex === 0 ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.herdrPromptIndex = 0
                    onClicked: {
                      root.herdrPromptIndex = 0
                      root.confirmHerdrPrompt()
                    }
                  }
                }

                BorderSurface {
                  width: Style.space(96)
                  height: Style.space(34)
                  color: root.herdrPromptIndex === 1 ? Util.alpha(Color.accent, 0.18) : "transparent"
                  borderSpec: Border.flat(
                    root.herdrPromptIndex === 1 ? Color.accent : Util.alpha(Color.accent, 0.56),
                    Style.normalBorderWidth)
                  radius: 0
                  Text {
                    anchors.centerIn: parent
                    text: "Herdr"
                    color: root.herdrPromptIndex === 1 ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.herdrPromptIndex = 1
                    onClicked: {
                      root.herdrPromptIndex = 1
                      root.confirmHerdrPrompt()
                    }
                  }
                }
              }
            }
          }
        }
      }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search AI sessions…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              width: Math.round(parent.width * 0.42)
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Column {
                  id: row
                  required property int index
                  required property string sessionId
                  required property string source
                  required property string title
                  required property string project
                  required property string cwd
                  required property string modelName
                  required property string snippet
                  required property string updatedLabel
                  required property string dayGroup
                  required property bool showDayHeader
                  required property string mark
                  required property int messageCount

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                  width: ListView.view.width
                  spacing: Style.space(2)

                  Text {
                    visible: row.showDayHeader
                    width: parent.width
                    height: visible ? Style.space(26) : 0
                    text: row.dayGroup
                    color: Color.accent
                    opacity: 0.9
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.weight: Font.Medium
                    verticalAlignment: Text.AlignBottom
                    elide: Text.ElideRight
                  }

                  Rectangle {
                    width: parent.width
                    height: root.rowHeight
                    radius: root.cornerRadius
                    color: row.hasCursor ? root.selectedBackground : "transparent"

                    Rectangle {
                      visible: row.hasCursor
                      width: Style.space(3)
                      height: parent.height - Style.space(10)
                      radius: width
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(4)
                      color: Color.accent
                    }

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(14)
                      anchors.rightMargin: Style.space(12)
                      anchors.topMargin: Style.space(8)
                      anchors.bottomMargin: Style.space(8)
                      spacing: Style.space(10)

                      Item {
                        width: Style.space(22)
                        height: parent.height

                        Image {
                          visible: row.mark.length > 0
                          anchors.centerIn: parent
                          width: Style.space(16)
                          height: Style.space(16)
                          source: row.mark
                          fillMode: Image.PreserveAspectFit
                          asynchronous: true
                          smooth: true
                        }

                        Text {
                          visible: row.mark.length === 0
                          anchors.centerIn: parent
                          text: row.source ? row.source.charAt(0).toUpperCase() : "?"
                          color: row.hasCursor ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      Column {
                        width: parent.width - Style.space(32)
                        spacing: Style.space(3)

                        Text {
                          width: parent.width
                          text: row.title
                          color: row.hasCursor ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.title
                          font.weight: Font.Medium
                          elide: Text.ElideRight
                        }

                        Text {
                          width: parent.width
                          text: [row.project || row.cwd, row.updatedLabel, row.messageCount ? row.messageCount + " turns" : ""].filter(function(part) { return part && part.length }).join("  ·  ")
                          color: root.foreground
                          opacity: 0.52
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                        }
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: function(mouse) {
                        root.selectFromPointer(row.index, row, mouse)
                      }
                      onClicked: {
                        root.cursorActive = true
                        root.selectedIndex = row.index
                        root.activateIndex(row.index)
                      }
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width - Math.round(parent.width * 0.42)
              height: parent.height
              clip: true

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Flickable {
                id: previewFlick
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                contentWidth: width
                contentHeight: previewColumn.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                Column {
                  id: previewColumn
                  width: previewFlick.width
                  spacing: Style.space(10)

                  Text {
                    width: parent.width
                    visible: !!root.currentRow()
                    text: root.currentRow() ? root.currentRow().title : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.weight: Font.Medium
                    wrapMode: Text.Wrap
                  }

                  Text {
                    width: parent.width
                    visible: !!root.currentRow()
                    text: {
                      var row = root.currentRow()
                      if (!row) return ""
                      var bits = [row.source, row.project || row.cwd, row.modelName, row.updatedLabel]
                      return bits.filter(function(part) { return part && part.length }).join("  ·  ")
                    }
                    color: root.foreground
                    opacity: 0.52
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                  }

                  Row {
                    spacing: Style.space(8)
                    visible: !!root.currentRow()

                    Rectangle {
                      height: Style.space(24)
                      width: copyLabel.implicitWidth + Style.space(16)
                      radius: height / 2
                      color: Util.alpha(root.foreground, 0.06)
                      border.width: Style.normalBorderWidth
                      border.color: Util.alpha(root.border, 0.2)
                      Text {
                        id: copyLabel
                        anchors.centerIn: parent
                        text: "Copy"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.copySession()
                      }
                    }

                    Rectangle {
                      height: Style.space(24)
                      width: openLabel.implicitWidth + Style.space(16)
                      radius: height / 2
                      color: root.handoffOpen ? Util.alpha(Color.accent, 0.18) : Util.alpha(root.foreground, 0.06)
                      border.width: Style.normalBorderWidth
                      border.color: root.handoffOpen ? Util.alpha(Color.accent, 0.7) : Util.alpha(root.border, 0.2)
                      Text {
                        id: openLabel
                        anchors.centerIn: parent
                        text: "Open in…"
                        color: root.handoffOpen ? Color.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleHandoff()
                      }
                    }
                  }

                  ListView {
                    visible: root.handoffOpen && targetModel.count > 0
                    width: parent.width
                    height: visible ? Style.space(28) : 0
                    orientation: ListView.Horizontal
                    spacing: Style.space(6)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: targetModel

                    delegate: Rectangle {
                      id: targetChip
                      required property int index
                      required property string targetId
                      required property string targetName
                      required property string mark
                      readonly property bool active: index === root.handoffIndex

                      height: Style.space(26)
                      width: targetChipLabel.implicitWidth + (mark.length > 0 ? Style.space(28) : Style.space(16))
                      radius: height / 2
                      color: active ? Util.alpha(Color.accent, 0.18) : Util.alpha(root.foreground, 0.04)
                      border.width: Style.normalBorderWidth
                      border.color: active ? Util.alpha(Color.accent, 0.7) : Util.alpha(root.border, 0.18)

                      Row {
                        anchors.centerIn: parent
                        spacing: Style.space(6)
                        Image {
                          visible: targetChip.mark.length > 0
                          width: Style.space(12)
                          height: Style.space(12)
                          anchors.verticalCenter: parent.verticalCenter
                          source: targetChip.mark
                          fillMode: Image.PreserveAspectFit
                          asynchronous: true
                          smooth: true
                        }
                        Text {
                          id: targetChipLabel
                          anchors.verticalCenter: parent.verticalCenter
                          text: targetChip.targetName
                          color: targetChip.active ? Color.accent : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.handoffIndex = targetChip.index
                          root.openInAgent(targetChip.targetId)
                        }
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: root.previewLoading && !root.previewText
                    text: "Reading transcript…"
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: parent.width
                    visible: !root.previewLoading && root.previewText.length === 0 && !!root.currentRow()
                    text: "No transcript preview for this session."
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: parent.width
                    visible: root.previewText.length > 0
                    text: root.previewText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                    lineHeight: 1.28
                  }
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: !root.loading && displayModel.count === 0
            width: parent.width * 0.7

            Text {
              width: parent.width
              text: "󰑴"
              color: Color.accent
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: root.errorText ? root.errorText
                : (root.payload.sessions.length === 0 ? "No sessions on this machine yet" : "No matches for “" + root.filterText + "”")
              color: root.foreground
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              visible: !root.errorText && root.payload.sessions.length === 0
              text: "Launch an agent once and it will show up here. Extra tools can register themselves the same way Omarchy usage collectors do."
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }

        }

        Text {
          width: parent.width
          height: root.footerHeight
          text: root.statusText
            ? root.statusText
            : (root.loading
              ? "Gathering sessions…"
              : (root.herdrPromptOpen
                ? "Enter:confirm  |  ←→:pick  |  Esc:cancel"
                : (root.handoffOpen
                  ? "Enter:start there  |  ←→:pick agent  |  Esc:cancel"
                  : (root.herdrRunning
                    ? "Enter:resume in Herdr  |  Tab:change grouping (" + root.groupBy + ")  |  Ctrl+Y:copy  |  Ctrl+O:open in  |  Esc:close"
                    : "Enter:resume  |  Tab:change grouping (" + root.groupBy + ")  |  Ctrl+Y:copy  |  Ctrl+O:open in  |  Esc:close"))))
          color: (root.statusText || root.loading) ? Color.accent : root.foreground
          opacity: (root.statusText || root.loading) ? 0.85 : 0.42
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }
}
