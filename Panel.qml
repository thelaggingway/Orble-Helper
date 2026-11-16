import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Orble: sandboxes for AI agents, in the bar.
//
// All CLI work happens in bin/orble-panel, which calls the signed-in `orble`
// CLI with a fixed argv. This file polls `status` (and a box's shared ports
// when it is expanded), draws the panel, opens SSH,
// the VNC desktop, top-ups and sign-in in a terminal, runs actions as child
// processes (the helper sends the notification), and owns the exit node
// process (stopped with SIGINT, like Ctrl-C).
Panel {
  id: root
  moduleName: "thelaggingway.orble-helper"
  ipcTarget: "thelaggingway.orble-helper"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string helper: pluginDir + "bin/orble-panel"

  readonly property int refreshIntervalSec: Math.max(30, setting("refreshIntervalSec", 120))
  readonly property real lowCreditUSD: Math.max(0, Number(setting("lowCreditUSD", 1)) || 0)
  // On/off settings may arrive as booleans or as "true"/"false" strings (omarchy bar set without --json).
  function flag(name, fallback) {
    var v = setting(name, fallback)
    return v === true || v === "true" ? true : (v === false || v === "false" ? false : fallback)
  }
  readonly property bool showCount: flag("showCount", true)
  readonly property bool showCredit: flag("showCredit", true)
  // Made-up data for screenshots: the helper never calls the CLI, and actions do nothing.
  readonly property bool demo: flag("demoMode", false)
  readonly property var demoArg: demo ? ["--demo"] : []

  property var status: null
  property bool loading: false
  property real lastRefreshAt: 0
  property real now: Date.now() / 1000

  // ---------- UI state ----------
  property string expandedBox: ""
  property bool topupOpen: false
  property bool newOpen: false
  property string newSize: "s"
  property string topupChoice: "25"
  property bool keysOpen: false
  property bool snapshotsOpen: false
  // The box whose "save a snapshot" row is open, and the name typed there (empty: the CLI picks).
  property string snapFor: ""
  property string snapName: ""
  // The snapshot whose "new box from it" sizes are open, and the size picked.
  property string fromSnap: ""
  property string fromSize: "s"
  // box -> [{port, access, url}] from `orble-panel ports <box>`, loaded when a box is expanded.
  property var ports: ({})
  property var portsLoading: ({})
  property string portInput: ""
  // While a text field has focus, keys go to it instead of the panel's shortcuts.
  property bool editorFocus: false
  // Pending confirmation: { verb, target, args, extra }
  property var confirm: null
  // target -> verb for actions in flight
  property var pending: ({})
  readonly property int pendingCount: Object.keys(pending).length

  // ---------- exit node ----------
  property var exitBoxes: []
  property bool exitLan: false
  property bool exitFallback: false
  property string exitLine: ""
  readonly property bool exitOn: exitProc.running
  readonly property var exitOpts: ({ boxes: exitBoxes, lan: exitLan, fallback: exitFallback })

  // Keep awake: one helper process holds an idle `orble ssh` per box, so it doesn't auto-suspend.
  property var awakeBoxes: []
  property string awakeKey: ""   // the box list the running helper was started with
  property string awakeLine: ""

  readonly property int running: Model.runningCount(status)
  readonly property bool healthy: status !== null && status.ok === true
  readonly property var boxes: healthy ? status.boxes : []
  readonly property var account: healthy ? status.account : null
  readonly property var keys: healthy ? status.keys : []
  readonly property var snapshots: healthy ? status.snapshots : []
  readonly property bool hasSnapshots: healthy && status.snapshotsSupported
  readonly property var newLocalKeys: healthy ? status.localKeys.filter(function(k) { return !k.added }) : []
  readonly property bool hasViewer: healthy && status.viewer !== ""
  readonly property bool lowCredit: Model.creditLow(account, lowCreditUSD)

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property real labelWidth: Style.space(84)

  // ---------- data ----------

  function refresh() {
    if (statusProc.running) return
    root.loading = true
    statusProc.running = true
  }

  function applyStatus(text) {
    root.loading = false
    var next = Model.parseStatus(text)
    if (!next) return
    root.status = next
    root.lastRefreshAt = Date.now() / 1000
    root.now = root.lastRefreshAt
    // Drop exit-node picks for boxes that are gone.
    var names = next.boxes.map(function(b) { return b.name })
    var kept = root.exitBoxes.filter(function(n) { return names.indexOf(n) >= 0 })
    if (kept.length !== root.exitBoxes.length && !root.exitOn) root.exitBoxes = kept
    var awake = root.awakeBoxes.filter(function(n) { return names.indexOf(n) >= 0 })
    if (awake.length !== root.awakeBoxes.length) setAwake(awake)
    var snaps = next.snapshots.map(function(x) { return x.name })
    if (root.fromSnap && snaps.indexOf(root.fromSnap) < 0) root.fromSnap = ""
  }

  // ----- shared ports (per box, on demand: `orble port <box>` has no JSON and one call per box) -----

  function loadPorts(name) {
    if (!Model.validName(name) || root.portsLoading[name]) return
    var proc = portsComponent.createObject(root, { box: name, command: [root.helper, "ports", name].concat(root.demoArg) })
    if (!proc) return
    setMap("portsLoading", name, true)
    proc.running = true
  }

  function applyPorts(name, text) {
    setMap("portsLoading", name, false)
    var d = null
    try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
    if (!d || d.box !== name) return
    setMap("ports", name, d.ok ? (d.ports || []) : { error: String(d.error || "") })
  }

  function portsOf(name) {
    var p = root.ports[name]
    return p && typeof p.length === "number" ? p : []
  }

  function portsError(name) {
    var p = root.ports[name]
    return p && typeof p.length !== "number" ? p.error : ""
  }

  function setMap(prop, key, value) {
    var next = Object.assign({}, root[prop])
    if (value === false || value === undefined) delete next[key]
    else next[key] = value
    root[prop] = next
  }

  function sharePort(name, port, publicly) {
    port = String(port || "").trim()
    if (!Model.validName(name) || !Model.validPort(port)) return
    root.portInput = ""
    if (publicly) request("port-public", name + ":" + port, [name, port])
    else runAction("port", [name, port], "port:" + name + ":" + port)
  }

  function unsharePort(name, port) {
    runAction("port-off", [name, String(port)], "port:" + name + ":" + port)
  }

  // ----- snapshots -----

  function saveSnapshot(name) {
    var n = root.snapName.trim()
    if (!Model.validName(name) || !Model.validSnapshotName(n)) return
    root.snapFor = ""
    root.snapName = ""
    runAction("snapshot", n ? [name, n] : [name], name)
  }

  function newFromSnapshot(snap, size) {
    root.fromSnap = ""
    runAction("new-from", [snap.name, size], "snap:" + snap.name)
  }

  // ---------- actions ----------

  function setPending(target, verb) {
    var next = Object.assign({}, root.pending)
    if (verb) next[target] = verb
    else delete next[target]
    root.pending = next
  }

  function demoNotice() {
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Orble", "-u", "low", "Demo data is on", "Nothing was changed. Turn off Demo data in the plugin settings."])
  }

  // target: what the pending marker is keyed on (defaults to the first argument).
  function runAction(verb, args, target) {
    if (root.demo) { demoNotice(); return }
    var key = target || args[0] || verb
    if (root.pending[key]) return
    var proc = opComponent.createObject(root, { target: key, command: [root.helper, "action", verb].concat(args) })
    if (!proc) return
    setPending(key, verb)
    proc.running = true
  }

  function finishAction(target) {
    setPending(target, "")
    var m = /^port:([^:]+):/.exec(target)
    if (m) loadPorts(m[1])
    refresh()
  }

  // A helper subcommand in a terminal window: ssh, desktop, topup, login.
  function openTerminal(args) {
    if (root.demo) { demoNotice(); return }
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.orble", root.helper].concat(args))
    root.close()
    wakeRefresh.restart()
  }

  readonly property var confirmVerbs: ["rm", "keys-rm", "topup", "fork", "snapshot-rm", "port-public"]

  // Destructive or paying verbs go through the confirm dialog first.
  function request(verb, target, args, extra) {
    var a = args || [target]
    if (confirmVerbs.indexOf(verb) >= 0) {
      root.confirm = { verb: verb, target: target, args: a, extra: extra || "" }
      Qt.callLater(function() { confirmKeys.forceActiveFocus() })
    } else {
      // Keep awake would reconnect and resume a box you just suspended, so suspending ends it.
      if (verb === "suspend" && isAwake(target)) setAwake(Model.toggled(root.awakeBoxes, target))
      runAction(verb, a)
    }
  }

  function confirmAccepted() {
    var c = root.confirm
    root.confirm = null
    keyCatcher.forceActiveFocus()
    if (!c) return
    if (c.verb === "topup") {
      root.topupOpen = false
      openTerminal(["topup"].concat(c.args))
    } else if (c.verb === "port-public") {
      runAction(c.verb, c.args, "port:" + c.args[0] + ":" + c.args[1])
    } else if (c.verb === "snapshot-rm") {
      runAction(c.verb, c.args, "snap:" + c.args[0])
    } else {
      runAction(c.verb, c.args)
    }
  }

  function confirmCanceled() {
    root.confirm = null
    keyCatcher.forceActiveFocus()
  }

  // size: "s", "m" or "l" (orble new -s); empty keeps the CLI's default.
  function newBox(size) {
    root.newOpen = false
    runAction("new", size ? [size] : [], "new")
  }

  function ssh(name) {
    if (!Model.validName(name)) return
    openTerminal(["ssh", name])
  }

  function copyText(t) {
    if (!/^https:\/\//.test(t)) return
    Quickshell.execDetached(["wl-copy", t])
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Orble", "-u", "low", "Copied", t])
  }

  function copySsh(b) {
    if (!Model.validName(b.name)) return
    var cmd = Model.sshCommand(b)
    Quickshell.execDetached(["wl-copy", cmd])
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Orble", "-u", "low", "Copied", cmd])
  }

  function signIn() { openTerminal(["login"]) }

  function openUrl(url) {
    if (/^https:\/\//.test(url)) Quickshell.execDetached(["xdg-open", url])
  }

  function toggleBox(b) {
    root.expandedBox = root.expandedBox !== b.name ? b.name : ""
    root.snapFor = ""
    root.portInput = ""
    if (root.expandedBox) loadPorts(root.expandedBox)
  }

  // ----- exit node -----

  function startExit() {
    if (root.exitOn || !root.healthy) return
    root.exitLine = ""
    exitProc.command = [root.helper, "exit-node"].concat(Model.exitNodeArgs(root.exitOpts)).concat(root.demoArg)
    exitProc.running = true
  }

  function stopExit() {
    if (!root.exitOn) return
    exitProc.signal(2)  // SIGINT, as Ctrl-C: the CLI puts the boxes back on Orble's network
    exitKill.restart()
  }

  function toggleExit() { root.exitOn ? stopExit() : startExit() }

  // ----- keep awake -----

  function isAwake(name) { return root.awakeBoxes.indexOf(name) >= 0 }

  function setAwake(list) {
    root.awakeBoxes = list.filter(function(n) { return Model.validName(n) })
    applyAwake()
  }

  function toggleAwake(name) { setAwake(Model.toggled(root.awakeBoxes, name)) }

  // Restart the helper whenever the list changes; onExited starts it again with the new list.
  function applyAwake() {
    if (awakeProc.running) {
      if (JSON.stringify(root.awakeBoxes) !== root.awakeKey) { awakeProc.signal(15); awakeKill.restart() }
      return
    }
    if (root.awakeBoxes.length === 0) { root.awakeLine = ""; return }
    root.awakeKey = JSON.stringify(root.awakeBoxes)
    awakeProc.command = [root.helper, "keep-awake"].concat(root.awakeBoxes).concat(root.demoArg)
    awakeProc.running = true
  }

  onDemoChanged: { stopExit(); setAwake([]); root.status = null; refresh() }

  onOpenedChanged: {
    if (!opened) {
      root.confirm = null
      root.topupOpen = false
      root.snapFor = ""
      root.fromSnap = ""
      return
    }
    root.now = Date.now() / 1000
    if (root.now - root.lastRefreshAt > 8) refresh()
    if (root.expandedBox) loadPorts(root.expandedBox)
  }

  IpcHandler {
    target: "thelaggingway.orble-helper"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function newBox(): void { root.newBox() }
    function exitNode(): void { root.toggleExit() }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"].concat(root.demoArg)
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(exitCode) { if (exitCode !== 0) root.loading = false }
  }

  Process {
    id: exitProc
    stdout: SplitParser { onRead: function(data) { var l = Model.cleanLine(data); if (l) root.exitLine = l } }
    stderr: SplitParser { onRead: function(data) { var l = Model.cleanLine(data); if (l) root.exitLine = l } }
    onExited: function(exitCode) {
      exitKill.stop()
      if (exitCode !== 0 && exitCode !== 130 && root.exitLine === "") root.exitLine = "Stopped (exit " + exitCode + ")"
      root.refresh()
    }
  }

  Process {
    id: awakeProc
    stdout: SplitParser { onRead: function(data) { var l = Model.cleanLine(data); if (l) root.awakeLine = l } }
    onExited: function(exitCode) {
      awakeKill.stop()
      var wanted = JSON.stringify(root.awakeBoxes)
      if (wanted !== root.awakeKey) { root.awakeKey = ""; applyAwake(); return }
      // It stopped by itself (signed out, bad name): don't loop, show why.
      root.awakeKey = ""
      if (root.awakeBoxes.length > 0) {
        root.awakeBoxes = []
        if (root.awakeLine === "" || root.awakeLine.indexOf("Keeping") === 0) root.awakeLine = "Keep awake stopped (exit " + exitCode + ")"
      }
    }
  }

  Timer { id: awakeKill; interval: 8000; onTriggered: if (awakeProc.running) awakeProc.running = false }

  // If the CLI ignores SIGINT for 10 s, end it.
  Timer { id: exitKill; interval: 10000; onTriggered: if (exitProc.running) exitProc.running = false }

  Component {
    id: portsComponent
    Process {
      property string box: ""
      // stdout always finishes (empty on a failure), so it clears the loading mark and cleans up.
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.applyPorts(box, text); destroy() } }
    }
  }

  Component {
    id: opComponent
    Process {
      property string target: ""
      onExited: function() {
        root.finishAction(target)
        destroy()
      }
    }
  }

  Timer { interval: 4000; running: true; onTriggered: root.refresh() }

  Timer {
    interval: root.opened || root.pendingCount > 0 ? 10000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: { root.now = Date.now() / 1000; root.refresh() }
  }

  // After a terminal launch (ssh resumes the box; topup and login change the account), look again.
  Timer { id: wakeRefresh; interval: 15000; onTriggered: root.refresh() }

  // ---------- bar icon ----------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool countShown: root.showCount && root.running > 0 && !button.vertical

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.icons.server + (root.countShown ? " " + root.running : "") + (root.exitOn && !vertical ? " " + Model.icons.earth : "")
    slotSize: Style.bar.iconSlot * (1 + (root.countShown ? (root.running > 9 ? 1 : 0.6) : 0) + (root.exitOn && !vertical ? 0.9 : 0))
    opacity: root.running > 0 || root.pendingCount > 0 || root.exitOn ? 1 : 0.55
    active: (root.status !== null && !root.healthy) || root.lowCredit
    tooltipText: root.opened ? "" : Model.tooltip(root.status, root.running, root.exitOn)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirm !== null || root.editorFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // ---------- hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            PlainText {
              id: heroIcon
              text: Model.icons.server
              color: root.healthy ? root.foreground : root.urgent
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: newButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PlainText {
                text: "Orble"
                font.pixelSize: Style.font.title
                font.bold: true
                width: parent.width
              }

              PlainText {
                text: Model.headline(root.status, root.running).toUpperCase()
                color: root.healthy || root.status === null ? root.muted : root.urgent
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                width: parent.width
              }
            }

            PanelActionButton {
              id: newButton
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.healthy
              iconText: Model.icons.plus
              tooltipText: root.pending["new"] ? "Creating a box…" : "New box (orble new -s …)"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              enabled: !root.pending["new"]
              opacity: enabled ? 1 : 0.4
              onClicked: root.newOpen = !root.newOpen
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.refresh
              tooltipText: root.loading ? "Refreshing…" : "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.loading
              opacity: enabled ? 1 : 0.4
              onClicked: root.refresh()
            }
          }

          // ---------- error ----------
          Column {
            visible: root.status !== null && !root.healthy
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              width: parent.width
              wrapMode: Text.Wrap
              maximumLineCount: 4
              text: root.status ? root.status.error : ""
              color: root.urgent
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: root.status !== null && root.status.authError === true
              iconText: Model.icons.login
              text: "Sign in to Orble"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.signIn()
            }
          }

          // ---------- new box size ----------
          Row {
            visible: root.healthy && root.newOpen && !root.pending["new"]
            spacing: Style.space(8)

            Chips {
              anchors.verticalCenter: parent.verticalCenter
              options: Model.sizeOptions
              value: root.newSize
              onChanged: function(v) { root.newSize = v }
            }

            ActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.plus
              foreground: root.accent
              text: Model.createLabel(root.newSize)
              tooltipText: Model.sizeTooltip(root.newSize)
              onClicked: root.newBox(root.newSize)
            }
          }

          // ---------- credit ----------
          CreditCard { visible: root.showCredit && root.account !== null }

          // ---------- boxes ----------
          PanelSectionHeader {
            visible: root.healthy
            text: "BOXES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PlainText {
            visible: root.healthy && root.boxes.length === 0 && !root.pending["new"]
            text: "No boxes. Use + to create one."
            color: root.muted
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            visible: root.pending["new"] === "new"
            spacing: Style.space(10)
            leftPadding: Style.space(6)
            StateDot { tone: "busy"; anchors.verticalCenter: parent.verticalCenter }
            PlainText {
              text: "Creating a box…"
              color: root.muted
              font.pixelSize: Style.font.bodySmall
            }
          }

          Repeater {
            model: root.boxes
            delegate: BoxRow {}
          }

          // Keep awake's last word when it reconnects or stops by itself.
          PlainText {
            visible: root.healthy && root.awakeLine !== "" && root.awakeLine.indexOf("Keeping") !== 0
            width: parent.width
            text: Model.icons.coffee + "  " + root.awakeLine
            color: root.muted
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // ---------- snapshots ----------
          Item {
            visible: root.hasSnapshots
            width: parent.width
            implicitHeight: snapsHeader.implicitHeight

            PanelSectionHeader {
              id: snapsHeader
              text: "SNAPSHOTS " + (root.snapshotsOpen ? "▾" : "▸") + "  " + root.snapshots.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.snapshotsOpen = !root.snapshotsOpen
            }
          }

          Repeater {
            model: root.snapshotsOpen ? root.snapshots : []
            delegate: SnapshotRow {}
          }

          PlainText {
            visible: root.hasSnapshots && root.snapshotsOpen && root.snapshots.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "No snapshots. Open a box and use Snapshot to save one; new boxes can start from it."
            color: root.muted
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          // ---------- exit node ----------
          ExitNodeCard { visible: root.healthy }

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          // ---------- ssh keys ----------
          Item {
            visible: root.healthy
            width: parent.width
            implicitHeight: keysHeader.implicitHeight

            PanelSectionHeader {
              id: keysHeader
              text: "SSH KEYS " + (root.keysOpen ? "▾" : "▸") + "  " + root.keys.length
                + (root.newLocalKeys.length ? "  · " + root.newLocalKeys.length + " local not added" : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.keysOpen = !root.keysOpen
            }
          }

          Repeater {
            model: root.keysOpen ? root.keys : []
            delegate: KeyRow {}
          }

          Repeater {
            model: root.keysOpen ? root.newLocalKeys : []
            delegate: LocalKeyRow {}
          }

          PlainText {
            visible: root.healthy && root.keysOpen && root.keys.length === 0 && root.newLocalKeys.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "No keys on the account and no .pub files in ~/.ssh. Make one with ssh-keygen -t ed25519."
            color: root.muted
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- footer ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(footerText.implicitHeight, dashButton.implicitHeight)

            PlainText {
              id: footerText
              anchors.left: parent.left
              anchors.right: updateButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.demo ? "demo data"
                : (root.loading ? "refreshing…" : (root.lastRefreshAt ? "updated " + Model.ago(root.now, root.lastRefreshAt) : "loading…"))
              color: root.muted
              font.pixelSize: Style.font.caption
            }

            ActionButton {
              id: updateButton
              anchors.right: dashButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.update
              text: root.pending["cli"] ? "Updating…" : "Update CLI"
              tooltipText: "orble update"
              enabled: !root.pending["cli"]
              opacity: enabled ? 1 : 0.4
              onClicked: root.runAction("update", [], "cli")
            }

            ActionButton {
              id: dashButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.link
              text: "Dashboard"
              tooltipText: "Open the Orble dashboard"
              onClicked: { root.openUrl("https://orble.tech/dashboard"); root.close() }
            }
          }
        }
      }

      // Confirm dialog over the panel; Keys go to it while it is open.
      FocusScope {
        id: confirmKeys
        anchors.fill: parent
        visible: root.confirm !== null
        z: 10
        Keys.onPressed: function(event) { event.accepted = confirmDialog.handleKey(event) }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.confirm !== null
          message: root.confirm ? Model.confirmText(root.confirm.verb, root.confirm.target, root.confirm.extra) : ""
          confirmText: Model.confirmButton(root.confirm ? root.confirm.verb : "")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onConfirmed: root.confirmAccepted()
          onCanceled: root.confirmCanceled()
        }
      }
    }
  }

  // ---------- components ----------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component StateDot: Rectangle {
    property string tone: "off"
    width: Style.space(8)
    height: width
    radius: width / 2
    color: tone === "on" ? root.accent : (tone === "bad" ? root.urgent : (tone === "busy" ? root.foreground : root.muted))
    opacity: tone === "off" ? 0.6 : 1
    SequentialAnimation on opacity {
      running: tone === "busy"
      loops: Animation.Infinite
      NumberAnimation { to: 0.3; duration: 600 }
      NumberAnimation { to: 1; duration: 600 }
    }
  }

  component ActionButton: Button {
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
  }

  component Chips: ButtonGroup {
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  component FieldLabel: PlainText {
    width: root.labelWidth
    color: root.muted
    font.pixelSize: Style.font.caption
  }

  component CreditCard: Column {
    id: cc
    width: column.width
    spacing: Style.space(6)
    readonly property var a: root.account

    Item {
      width: parent.width
      implicitHeight: creditTop.implicitHeight

      Row {
        id: creditTop
        width: parent.width
        spacing: Style.space(8)

        PlainText {
          id: creditLabel
          text: Model.icons.cash + "  CREDIT"
          color: root.muted
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          anchors.verticalCenter: parent.verticalCenter
        }

        PlainText {
          width: parent.width - creditLabel.implicitWidth - topupButton.implicitWidth - parent.spacing * 2
          horizontalAlignment: Text.AlignRight
          text: cc.a && cc.a.creditUSD !== null ? Model.money(cc.a.creditUSD) : "—"
          color: root.lowCredit ? root.urgent : root.foreground
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        ActionButton {
          id: topupButton
          iconText: Model.icons.plus
          text: "Add credit"
          active: root.topupOpen
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.topupOpen = !root.topupOpen
        }
      }
    }

    PlainText {
      width: parent.width
      text: cc.a ? [cc.a.email, cc.a.domain ? "<box>." + cc.a.domain + ".orble.tech" : ""].filter(function(p) { return p }).join(" · ") : ""
      color: root.lowCredit ? root.urgent : root.muted
      font.pixelSize: Style.font.caption
    }

    PlainText {
      visible: root.lowCredit
      width: parent.width
      wrapMode: Text.Wrap
      text: "Credit is low. Boxes need credit to run."
      color: root.urgent
      font.pixelSize: Style.font.caption
    }

    Row {
      visible: root.topupOpen
      width: parent.width
      spacing: Style.space(8)

      Chips {
        anchors.verticalCenter: parent.verticalCenter
        options: Model.topupOptions
        value: root.topupChoice
        onChanged: function(v) { root.topupChoice = v }
      }

      ActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.icons.cash
        text: "Top up"
        tooltipText: "orble topup " + root.topupChoice + " in a terminal"
        onClicked: root.request("topup", "$" + root.topupChoice, [root.topupChoice])
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }
  }

  component ExitNodeCard: Column {
    id: ex
    width: column.width
    spacing: Style.space(8)

    Item {
      width: parent.width
      implicitHeight: Math.max(exHead.implicitHeight, exToggle.implicitHeight)

      Column {
        id: exHead
        anchors.left: parent.left
        anchors.right: exToggle.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PlainText {
          text: Model.icons.earth + "  EXIT NODE"
          color: root.exitOn ? root.accent : root.muted
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        PlainText {
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          text: Model.exitSummary(root.exitOn, root.exitOpts, root.exitLine)
          color: root.exitOn ? root.foreground : root.muted
          font.pixelSize: Style.font.caption
        }
      }

      ActionButton {
        id: exToggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: root.exitOn ? Model.icons.close : Model.icons.play
        text: root.exitOn ? "Stop" : "Start"
        active: root.exitOn
        tooltipText: root.exitOn ? "Stop (as Ctrl-C): boxes go back to Orble's network" : "Send the boxes' traffic through this machine, from its IP"
        onClicked: root.toggleExit()
      }
    }

    PlainText {
      visible: root.exitOn && root.exitLine !== ""
      width: parent.width
      wrapMode: Text.Wrap
      maximumLineCount: 2
      text: root.exitLine
      color: root.muted
      font.pixelSize: Style.font.caption
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)
      enabled: !root.exitOn
      opacity: enabled ? 1 : 0.5
      visible: root.boxes.length > 0

      PlainText {
        text: "Boxes"
        width: root.labelWidth
        color: root.muted
        font.pixelSize: Style.font.caption
        height: lanButton.implicitHeight
        verticalAlignment: Text.AlignVCenter
      }

      Repeater {
        model: root.boxes
        ActionButton {
          required property var modelData
          text: modelData.name
          active: root.exitBoxes.indexOf(modelData.name) >= 0
          tooltipText: "Route " + modelData.name + " through this machine (none picked: the boxes switched on in the dashboard)"
          onClicked: root.exitBoxes = Model.toggled(root.exitBoxes, modelData.name)
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)
      enabled: !root.exitOn
      opacity: enabled ? 1 : 0.5

      PlainText {
        text: "Options"
        width: root.labelWidth
        color: root.muted
        font.pixelSize: Style.font.caption
        height: lanButton.implicitHeight
        verticalAlignment: Text.AlignVCenter
      }

      ActionButton {
        id: lanButton
        iconText: Model.icons.lan
        text: "LAN"
        active: root.exitLan
        tooltipText: "--lan: let boxes reach private addresses on this machine's network (LAN, VPN, tailnet)"
        onClicked: root.exitLan = !root.exitLan
      }

      ActionButton {
        iconText: Model.icons.refresh
        text: "Fallback"
        active: root.exitFallback
        tooltipText: "--fallback: use Orble's network while this machine is offline (without it, boxes have no internet then)"
        onClicked: root.exitFallback = !root.exitFallback
      }
    }
  }

  component BoxRow: Column {
    id: brow
    required property var modelData
    readonly property var b: modelData
    readonly property bool isOpen: root.expandedBox === b.name
    readonly property string busyVerb: root.pending[b.name] || ""
    readonly property bool isBusy: busyVerb !== "" || Model.stateTone(b) === "busy"
    readonly property bool isRunning: Model.isRunning(b)
    width: column.width
    spacing: Style.space(6)

    Rectangle {
      width: parent.width
      implicitHeight: head.implicitHeight + Style.space(10)
      radius: Style.space(4)
      color: headMouse.containsMouse || brow.isOpen ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"

      MouseArea {
        id: headMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleBox(brow.b)
      }

      Item {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        // Forks sit under the box they came from, like `orble ls`.
        anchors.leftMargin: Style.space(6) + (brow.b.depth || 0) * Style.space(14)
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: Math.max(labels.implicitHeight, sshButton.implicitHeight)

        StateDot {
          id: dot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          tone: brow.busyVerb !== "" ? "busy" : Model.stateTone(brow.b)
        }

        Column {
          id: labels
          anchors.left: dot.right
          anchors.leftMargin: Style.space(10)
          anchors.right: powerButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PlainText {
            width: parent.width
            text: brow.b.name
                  + (root.isAwake(brow.b.name) ? "  " + Model.icons.coffee : "")
                  + (root.exitOn && root.exitBoxes.indexOf(brow.b.name) >= 0 ? "  " + Model.icons.earth : "")
            font.bold: true
          }

          PlainText {
            width: parent.width
            text: Model.subline(brow.b, brow.busyVerb)
            color: root.muted
            font.pixelSize: Style.font.caption
          }
        }

        PanelActionButton {
          id: powerButton
          anchors.right: sshButton.left
          anchors.rightMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          iconText: brow.isRunning ? Model.icons.pause : Model.icons.play
          tooltipText: brow.isRunning ? "Suspend (processes kept; SSH resumes it)" : "Resume"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !brow.isBusy
          opacity: enabled ? 1 : 0.35
          onClicked: root.request(brow.isRunning ? "suspend" : "resume", brow.b.name)
        }

        PanelActionButton {
          id: sshButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.ssh
          tooltipText: brow.isRunning ? "SSH into " + brow.b.name : "Resume and SSH into " + brow.b.name
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          enabled: brow.busyVerb === "" || brow.busyVerb === "resume"
          opacity: enabled ? 1 : 0.35
          onClicked: root.ssh(brow.b.name)
        }
      }
    }

    // Expanded details and actions
    Column {
      visible: brow.isOpen
      width: parent.width
      leftPadding: Style.space(24)
      spacing: Style.space(8)
      readonly property real innerWidth: width - leftPadding

      PlainText {
        visible: text !== ""
        width: parent.innerWidth
        text: brow.b.host
        color: root.muted
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      PlainText {
        visible: text !== ""
        width: parent.innerWidth
        text: Model.detailLine(brow.b, root.isAwake(brow.b.name))
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      Flow {
        width: parent.innerWidth
        spacing: Style.space(6)
        enabled: !brow.isBusy
        opacity: enabled ? 1 : 0.4

        ActionButton {
          iconText: Model.icons.copy; text: "Copy SSH"
          tooltipText: "Copy \"" + Model.sshCommand(brow.b) + "\""
          onClicked: root.copySsh(brow.b)
        }
        ActionButton {
          readonly property bool on: root.isAwake(brow.b.name)
          iconText: Model.icons.coffee; text: on ? "Let it sleep" : "Keep awake"
          tooltipText: on ? "Stop holding a session open; it auto-suspends a minute later"
                          : "Hold an idle SSH session open so it doesn't auto-suspend (while this machine is on)"
          onClicked: root.toggleAwake(brow.b.name)
        }
        ActionButton {
          iconText: Model.icons.monitor; text: "Desktop"
          tooltipText: "orble vnc: the desktop in your browser (starts it if it isn't running)"
          onClicked: root.runAction("vnc", [brow.b.name])
        }
        ActionButton {
          visible: root.hasViewer
          iconText: Model.icons.monitor; text: "VNC viewer"
          tooltipText: "orble desktop: the desktop in " + (root.status ? root.status.viewer : "a VNC viewer") + ", over SSH"
          onClicked: root.openTerminal(["desktop", brow.b.name])
        }
        ActionButton {
          visible: Model.hasDesktop(brow.b)
          iconText: Model.icons.close; text: "Desktop off"
          tooltipText: "orble desktop --off"
          onClicked: root.runAction("desktop-off", [brow.b.name])
        }
        ActionButton {
          iconText: Model.icons.fork; text: "Fork"
          tooltipText: "orble fork: a new box carrying on from this one"
          onClicked: root.request("fork", brow.b.name)
        }
        ActionButton {
          visible: root.hasSnapshots
          iconText: Model.icons.camera; text: "Snapshot"
          active: root.snapFor === brow.b.name
          tooltipText: "orble snapshot: save this box to make new boxes from ($0.05 per GiB-month while kept)"
          onClicked: { root.snapFor = root.snapFor === brow.b.name ? "" : brow.b.name; root.snapName = "" }
        }
        ActionButton {
          iconText: Model.icons.trash; text: "Delete"
          foreground: root.urgent
          onClicked: root.request("rm", brow.b.name)
        }
      }

      // Save a snapshot: optional name, then Save.
      Row {
        visible: root.snapFor === brow.b.name && !brow.isBusy
        spacing: Style.space(6)

        TextField {
          id: snapField
          width: Style.space(170)
          anchors.verticalCenter: parent.verticalCenter
          placeholderText: "name (optional)"
          text: root.snapName
          maximumLength: 63
          font.pixelSize: Style.font.caption
          verticalPadding: Style.space(3)
          foreground: root.foreground
          accent: root.accent
          onTextEdited: root.snapName = text
          onActiveFocusChanged: root.editorFocus = activeFocus
          onAccepted: root.saveSnapshot(brow.b.name)
          Keys.onEscapePressed: { root.snapFor = ""; keyCatcher.forceActiveFocus() }
        }

        ActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.camera
          text: "Save"
          enabled: Model.validSnapshotName(root.snapName)
          opacity: enabled ? 1 : 0.4
          tooltipText: "orble snapshot " + brow.b.name + (root.snapName.trim() ? " " + root.snapName.trim() : "")
          onClicked: root.saveSnapshot(brow.b.name)
        }
      }

      PlainText {
        visible: root.snapFor === brow.b.name && root.snapName.trim() !== "" && !Model.validSnapshotName(root.snapName)
        width: parent.innerWidth
        text: "Letters, digits, dot, dash and underscore; starting with a letter or digit."
        color: root.urgent
        font.pixelSize: Style.font.caption
      }

      // Shared ports: each at its own https address.
      PlainText {
        width: parent.innerWidth
        text: Model.icons.share + "  PORTS" + (root.portsLoading[brow.b.name] ? "  ·  loading…" : "")
        color: root.muted
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Repeater {
        model: brow.isOpen ? root.portsOf(brow.b.name) : []
        delegate: PortRow { box: brow.b.name; rowWidth: brow.width - Style.space(24) }
      }

      PlainText {
        visible: brow.isOpen && root.portsError(brow.b.name) !== ""
        width: parent.innerWidth
        wrapMode: Text.Wrap
        maximumLineCount: 2
        text: root.portsError(brow.b.name)
        color: root.urgent
        font.pixelSize: Style.font.caption
      }

      Row {
        spacing: Style.space(6)

        TextField {
          id: portField
          width: Style.space(80)
          anchors.verticalCenter: parent.verticalCenter
          placeholderText: "port"
          text: root.expandedBox === brow.b.name ? root.portInput : ""
          maximumLength: 5
          inputMethodHints: Qt.ImhDigitsOnly
          validator: IntValidator { bottom: 1; top: 65535 }
          font.pixelSize: Style.font.caption
          verticalPadding: Style.space(3)
          foreground: root.foreground
          accent: root.accent
          onTextEdited: root.portInput = text
          onActiveFocusChanged: root.editorFocus = activeFocus
          onAccepted: root.sharePort(brow.b.name, root.portInput, false)
          Keys.onEscapePressed: { root.portInput = ""; keyCatcher.forceActiveFocus() }
        }

        ActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.lock
          text: "Share"
          enabled: Model.validPort(root.portInput)
          opacity: enabled ? 1 : 0.4
          tooltipText: "orble port " + brow.b.name + " " + (root.portInput || "<port>") + ": an https address only your Orble account can open"
          onClicked: root.sharePort(brow.b.name, root.portInput, false)
        }

        ActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.earth
          text: "Public"
          enabled: Model.validPort(root.portInput)
          opacity: enabled ? 1 : 0.4
          tooltipText: "orble port --public: anyone with the address can open it (accounts that have added credit)"
          onClicked: root.sharePort(brow.b.name, root.portInput, true)
        }
      }
    }
  }

  component PortRow: Item {
    id: prow
    required property var modelData
    property string box: ""
    property real rowWidth: column.width
    readonly property var p: modelData
    readonly property string busyVerb: root.pending["port:" + box + ":" + p.port] || ""
    width: rowWidth
    implicitHeight: Math.max(pcol.implicitHeight, poff.implicitHeight)

    Column {
      id: pcol
      anchors.left: parent.left
      anchors.right: popen.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      PlainText {
        width: parent.width
        text: prow.p.port + "  " + (prow.p.access === "public" ? Model.icons.earth : Model.icons.lock)
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      PlainText {
        width: parent.width
        text: prow.busyVerb ? Model.progressText[prow.busyVerb] + "…" : prow.p.url
        color: root.muted
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    PanelActionButton {
      id: popen
      anchors.right: pcopy.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.open
      tooltipText: "Open " + prow.p.url + " (" + Model.portAccess(prow.p) + ")"
      foreground: root.foreground
      hoverColor: root.accent
      fontFamily: root.fontFamily
      onClicked: { root.openUrl(prow.p.url); root.close() }
    }

    PanelActionButton {
      id: pcopy
      anchors.right: poff.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.copy
      tooltipText: "Copy the address"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.copyText(prow.p.url)
    }

    PanelActionButton {
      id: poff
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.close
      tooltipText: "Stop sharing (orble port --off)"
      foreground: root.urgent
      fontFamily: root.fontFamily
      enabled: prow.busyVerb === ""
      opacity: enabled ? 1 : 0.35
      onClicked: root.unsharePort(prow.box, prow.p.port)
    }
  }

  component SnapshotRow: Column {
    id: srow
    required property var modelData
    readonly property var sn: modelData
    readonly property string busyVerb: root.pending["snap:" + sn.name] || ""
    readonly property bool sizesOpen: root.fromSnap === sn.name
    width: column.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(scol.implicitHeight, snew.implicitHeight)

      PlainText {
        id: sicon
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: Model.icons.camera
        color: root.muted
        font.pixelSize: Style.font.bodySmall
      }

      Column {
        id: scol
        anchors.left: sicon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: snew.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        PlainText {
          width: parent.width
          text: srow.sn.name
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        PlainText {
          width: parent.width
          text: srow.busyVerb ? Model.progressText[srow.busyVerb] + "…" : Model.snapshotLine(srow.sn)
          color: root.muted
          font.pixelSize: Style.font.caption
        }
      }

      PanelActionButton {
        id: snew
        anchors.right: srm.left
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.icons.plus
        tooltipText: "New box from " + srow.sn.name + " (orble new --from)"
        foreground: root.foreground
        hoverColor: root.accent
        fontFamily: root.fontFamily
        enabled: srow.busyVerb === "" && srow.sn.state === "ready"
        opacity: enabled ? 1 : 0.35
        onClicked: {
          root.fromSnap = srow.sizesOpen ? "" : srow.sn.name
          root.fromSize = srow.sn.size || "s"
        }
      }

      PanelActionButton {
        id: srm
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.icons.trash
        tooltipText: "Delete the snapshot (orble snapshot rm)"
        foreground: root.urgent
        fontFamily: root.fontFamily
        enabled: srow.busyVerb === ""
        opacity: enabled ? 1 : 0.35
        onClicked: root.request("snapshot-rm", srow.sn.name, [srow.sn.name])
      }
    }

    Row {
      visible: srow.sizesOpen && srow.busyVerb === ""
      leftPadding: Style.space(24)
      spacing: Style.space(8)

      Chips {
        anchors.verticalCenter: parent.verticalCenter
        options: Model.sizesFrom(srow.sn)
        value: root.fromSize
        onChanged: function(v) { root.fromSize = v }
      }

      ActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.icons.plus
        foreground: root.accent
        text: Model.createLabel(root.fromSize)
        tooltipText: Model.fromTooltip(srow.sn, root.fromSize)
        onClicked: root.newFromSnapshot(srow.sn, root.fromSize)
      }
    }
  }

  component KeyRow: Item {
    id: krow
    required property var modelData
    readonly property var k: modelData
    readonly property string busyVerb: root.pending[k.fingerprint] || ""
    width: column.width
    implicitHeight: Math.max(kcol.implicitHeight, krm.implicitHeight)

    PlainText {
      id: kicon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.icons.key
      color: root.muted
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: kcol
      anchors.left: kicon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: krm.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      PlainText {
        width: parent.width
        text: krow.k.name || "(no name)"
        font.pixelSize: Style.font.bodySmall
      }
      PlainText {
        width: parent.width
        text: krow.busyVerb ? Model.progressText[krow.busyVerb] + "…" : Model.shortFingerprint(krow.k.fingerprint)
        color: root.muted
        font.pixelSize: Style.font.caption
      }
    }

    PanelActionButton {
      id: krm
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.trash
      tooltipText: "Remove from the account (orble keys rm)"
      foreground: root.urgent
      fontFamily: root.fontFamily
      enabled: krow.busyVerb === "" && Model.validFingerprint(krow.k.fingerprint)
      opacity: enabled ? 1 : 0.35
      onClicked: root.request("keys-rm", krow.k.name || Model.shortFingerprint(krow.k.fingerprint), [krow.k.fingerprint])
    }
  }

  component LocalKeyRow: Item {
    id: lrow
    required property var modelData
    readonly property var k: modelData
    readonly property string busyVerb: root.pending[k.file] || ""
    width: column.width
    implicitHeight: Math.max(lcol.implicitHeight, ladd.implicitHeight)

    PlainText {
      id: licon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.icons.key
      color: root.muted
      opacity: 0.5
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: lcol
      anchors.left: licon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: ladd.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      PlainText {
        width: parent.width
        text: "~/.ssh/" + lrow.k.file
        color: root.muted
        font.pixelSize: Style.font.bodySmall
      }
      PlainText {
        width: parent.width
        text: lrow.busyVerb ? Model.progressText[lrow.busyVerb] + "…" : "not added · " + [lrow.k.type, lrow.k.comment].filter(function(p) { return p }).join(" · ")
        color: root.muted
        font.pixelSize: Style.font.caption
      }
    }

    PanelActionButton {
      id: ladd
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.plus
      tooltipText: "Add to the account (orble keys add)"
      foreground: root.foreground
      hoverColor: root.accent
      fontFamily: root.fontFamily
      enabled: lrow.busyVerb === ""
      opacity: enabled ? 1 : 0.35
      onClicked: root.runAction("keys-add", [lrow.k.file])
    }
  }
}
