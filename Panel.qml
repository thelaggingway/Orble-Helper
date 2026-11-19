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
  property var deferredStatus: null
  property bool loading: false
  property bool statusReload: false
  property real lastRefreshAt: 0
  property real now: Date.now() / 1000

  // ---------- UI state ----------
  property string expandedBox: ""
  property bool topupOpen: false
  property bool newOpen: false
  property string newSize: "s"
  property string topupChoice: "25"
  // The box whose "save a snapshot" row is open, and the name typed there (empty: the CLI picks).
  property string snapFor: ""
  property string snapName: ""
  // The snapshot whose "new box from it" sizes are open, and the size picked.
  property string fromSnap: ""
  property string fromSize: "s"
  // box -> [{port, access, url}] from `orble-panel ports <box>`, loaded when a box is expanded.
  property var ports: ({})
  property var portsLoading: ({})
  property var portReload: ({})
  property string portInput: ""
  // While a text field has focus, keys go to it instead of the panel's shortcuts.
  property bool editorFocus: false
  // Pending confirmation: { verb, target, args, extra }
  property var confirm: null
  // target -> verb for actions in flight
  property var pending: ({})
  readonly property int pendingCount: Object.keys(pending).length

  property string newName: ""
  property string proSection: ""
  property string egressBox: ""
  property string renameBox: ""
  property string renameSnapshot: ""
  property var drafts: ({})
  property var details: ({})
  property var detailRequests: ({})
  property int detailSequence: 0
  readonly property bool modernCli: healthy && status.modernCli === true
  // `orble keep-awake` pins a box awake on Orble's side (CLI of 2026-11-19 and later).
  readonly property bool keepAwakeCli: healthy && status.keepAwakeSupported === true


  function boxLabel(name) {
    for (var i = 0; i < boxes.length; ++i)
      if (boxes[i].name === name) return boxes[i].alias || name
    return name
  }

  function loadDetail(kind, target) {
    var key = kind + (target ? ":" + target : "")
    var args = [root.helper, "detail", kind]
    if (target) args.push(target)
    var seq = ++root.detailSequence
    var proc = detailComponent.createObject(root, { key: key, sequence: seq, command: args.concat(root.demoArg) })
    if (!proc) return
    setMap("detailRequests", key, seq)
    setMap("details", key, { loading: true })
    proc.running = true
  }

  function applyDetail(key, seq, text) {
    if (root.detailRequests[key] !== seq) return
    setMap("detailRequests", key, false)
    var d
    try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
    setMap("details", key, d || { error: "Could not load Orble details." })
  }

  function invalidateDetail(key) {
    setMap("details", key, false)
    setMap("detailRequests", key, false)
  }

  function toggleEgress(box) {
    if (root.egressBox) invalidateDetail("egress:" + root.egressBox)
    root.egressBox = root.egressBox === box ? "" : box
    if (root.egressBox) loadDetail("egress", root.egressBox)
  }

  function togglePro(kind) {
    if (root.proSection) invalidateDetail(root.proSection)
    root.proSection = root.proSection === kind ? "" : kind
    if (root.proSection) loadDetail(kind, "")
  }

  function submitSecret(name, host, header, format, all, intercept, boxes, replacing) {
    var mode = (all ? "all" : "scoped") + (intercept ? "-intercept" : "")
    var args = ["secret-set", name, host, header, format, mode].concat(all ? [] : boxes)
    if (replacing || all || intercept)
      request("secret-set", name, args, (replacing ? " This replaces the existing value, scope, header settings, and interception choice." : "")
        + (all ? " This applies to every box on your account." : "")
        + (intercept ? " HTTPS interception adds Orble’s CA to the selected boxes." : ""))
    else
      openTerminal(args)
  }

  // ---------- exit node ----------
  property var exitBoxes: []
  property bool exitLan: false
  property bool exitFallback: false
  property string exitLine: ""
  readonly property bool exitOn: exitProc.running
  readonly property var exitOpts: ({ boxes: exitBoxes, lan: exitLan, fallback: exitFallback })

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

  function refresh(afterWrite) {
    if (statusProc.running) {
      if (afterWrite) root.statusReload = true
      return
    }
    root.loading = true
    statusProc.running = true
  }

  function applyStatus(text) {
    root.loading = false
    var next = Model.parseStatus(text)
    if (!next) return
    if (root.editorFocus && next.ok) {
      root.deferredStatus = next
      return
    }
    root.deferredStatus = null
    acceptStatus(next)
  }

  function acceptStatus(next) {
    root.status = next
    root.lastRefreshAt = Date.now() / 1000
    root.now = root.lastRefreshAt
    // Drop exit-node picks for boxes that are gone.
    var names = next.boxes.map(function(b) { return b.name })
    var kept = root.exitBoxes.filter(function(n) { return names.indexOf(n) >= 0 })
    if (kept.length !== root.exitBoxes.length && !root.exitOn) root.exitBoxes = kept
    var snaps = next.snapshots.map(function(x) { return x.name })
    if (root.fromSnap && snaps.indexOf(root.fromSnap) < 0) root.fromSnap = ""
  }

  // ----- shared ports (per box, on demand: `orble port <box>` has no JSON and one call per box) -----

  function loadPorts(name, afterWrite) {
    if (!Model.validName(name)) return
    if (root.portsLoading[name]) {
      if (afterWrite) setMap("portReload", name, true)
      return
    }
    var proc = portsComponent.createObject(root, { box: name, command: [root.helper, "ports", name].concat(root.demoArg) })
    if (!proc) return
    setMap("portsLoading", name, true)
    proc.running = true
  }

  function applyPorts(name, text) {
    setMap("portsLoading", name, false)
    if (root.portReload[name]) {
      setMap("portReload", name, false)
      loadPorts(name)
      return
    }
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
    if (m) loadPorts(m[1], true)
    if (target === "networks" || target === "secrets") {
      invalidateDetail(target)
      if (root.opened && root.proSection === target) loadDetail(target, "")
    }
    if (target.indexOf("egress:") === 0) {
      invalidateDetail(target)
      if (root.opened && root.egressBox === target.slice(7)) loadDetail("egress", root.egressBox)
    }
    refresh(true)
  }

  // A helper subcommand in a terminal window: ssh, desktop, topup, login.
  function openTerminal(args) {
    if (root.demo) { demoNotice(); return }
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.orble", root.helper].concat(args))
    root.close()
    wakeRefresh.restart()
  }

  readonly property var confirmVerbs: ["rm", "keys-rm", "topup", "fork", "snapshot-rm", "port-public", "resize", "net-block", "net-open", "net-allow", "net-deny", "net-rm", "net-delete", "net-leave", "secret-rm", "secret-set"]

  // Destructive or paying verbs go through the confirm dialog first.
  function request(verb, target, args, extra) {
    var a = args || [target]
    if (confirmVerbs.indexOf(verb) >= 0) {
      root.confirm = { verb: verb, target: target, args: a, extra: extra || "" }
      Qt.callLater(function() { confirmKeys.forceActiveFocus() })
    } else {
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
    } else if (c.verb === "secret-set") {
      openTerminal(c.args)
    } else if (c.verb === "net-delete" || c.verb === "net-leave") {
      runAction(c.verb, c.args, "networks")
    } else if (c.verb === "secret-rm") {
      runAction(c.verb, c.args, "secrets")
    } else if (["net-block", "net-open", "net-allow", "net-deny", "net-rm"].indexOf(c.verb) >= 0) {
      runAction(c.verb, c.args, "egress:" + c.args[0])
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
    if (size && root.modernCli && Model.validName(root.newName)) {
      runAction("new-named", [size, root.newName], "new")
      root.newName = ""
    } else runAction("new", size ? [size] : [], "new")
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
    if (root.egressBox) {
      invalidateDetail("egress:" + root.egressBox)
      root.egressBox = ""
    }
    if (root.renameBox) setMap("drafts", "rename:" + root.renameBox, false)
    root.renameBox = ""
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

  // ----- keep awake (server-side pin; status carries each box's keepAwake) -----

  function toggleAwake(b) {
    if (!Model.validName(b.name)) return
    runAction(b.keepAwake === true ? "keep-awake-off" : "keep-awake", [b.name])
  }

  onEditorFocusChanged: {
    if (!editorFocus && deferredStatus) Qt.callLater(function() {
      if (root.editorFocus || !root.deferredStatus) return
      var next = root.deferredStatus
      root.deferredStatus = null
      root.acceptStatus(next)
    })
  }

  onDemoChanged: { stopExit(); root.status = null; root.deferredStatus = null; root.details = {}; root.detailRequests = {}; root.proSection = ""; root.egressBox = ""; refresh() }

  onOpenedChanged: {
    if (!opened) {
      root.confirm = null
      root.topupOpen = false
      root.snapFor = ""
      root.fromSnap = ""
      if (root.proSection) invalidateDetail(root.proSection)
      if (root.egressBox) invalidateDetail("egress:" + root.egressBox)
      return
    }
    root.now = Date.now() / 1000
    if (root.now - root.lastRefreshAt > 8) refresh()
    if (root.expandedBox) loadPorts(root.expandedBox)
    if (root.proSection) loadDetail(root.proSection, "")
    if (root.egressBox) loadDetail("egress", root.egressBox)
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
    onExited: function(exitCode) {
      if (exitCode !== 0) root.loading = false
      if (root.statusReload) {
        root.statusReload = false
        Qt.callLater(function() { root.refresh() })
      }
    }
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
    id: detailComponent
    Process {
      property string key
      property int sequence
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { root.applyDetail(key, sequence, text); destroy() }
      }
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
              enabled: !root.modernCli || root.newName === "" || Model.validName(root.newName)
              tooltipText: Model.sizeTooltip(root.newSize)
              onClicked: root.newBox(root.newSize)
            }
          }

          KeyField {
            visible: root.healthy && root.newOpen && root.modernCli
            width: parent.width
            text: root.newName
            placeholderText: "Box name (optional)"
            onEdited: function(v) { root.newName = v }
            onAccepted: if (root.newName === "" || Model.validName(root.newName)) root.newBox(root.newSize)
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
            visible: !!root.pending["new"]
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

          // ---------- snapshots (always listed, like boxes) ----------
          PanelSectionHeader {
            visible: root.hasSnapshots
            text: "SNAPSHOTS  " + root.snapshots.length
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.hasSnapshots ? root.snapshots : []
            delegate: SnapshotRow {}
          }

          PlainText {
            visible: root.hasSnapshots && root.snapshots.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: "No snapshots. Open a box and use Snapshot to save one; new boxes can start from it."
            color: root.muted
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          Flow {
            visible: root.healthy
            width: parent.width
            spacing: Style.space(6)
            ActionButton { text: "Private networks"; active: root.proSection === "networks"; onClicked: root.togglePro("networks") }
            ActionButton { text: "Secrets"; active: root.proSection === "secrets"; onClicked: root.togglePro("secrets") }
          }
          NetworksCard { visible: root.healthy && root.proSection === "networks"; width: parent.width }
          SecretsCard { visible: root.healthy && root.proSection === "secrets"; width: parent.width }

          // ---------- exit node ----------
          ExitNodeCard { visible: root.healthy }

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          // ---------- ssh keys (always listed) ----------
          PanelSectionHeader {
            visible: root.healthy
            text: "SSH KEYS  " + root.keys.length
              + (root.newLocalKeys.length ? "  · " + root.newLocalKeys.length + " local not added" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.healthy ? root.keys : []
            delegate: KeyRow {}
          }

          Repeater {
            model: root.healthy ? root.newLocalKeys : []
            delegate: LocalKeyRow {}
          }

          PlainText {
            visible: root.healthy && root.keys.length === 0 && root.newLocalKeys.length === 0
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

  // A one-line entry that takes typed keys only. It deliberately has no Qt text input
  // (TextField/TextInput): a writable one fetches the clipboard on every clipboard change,
  // unbounded, so a hostile clipboard owner could stall the shell. No paste here, by design.
  component KeyField: Rectangle {
    id: kf
    property string text: ""
    property string placeholderText: ""
    property int maximumLength: 63
    property var allowed: /[A-Za-z0-9._-]/
    signal edited(string value)
    signal accepted()
    signal escaped()

    implicitHeight: kfText.implicitHeight + Style.space(6)
    radius: Style.space(4)
    color: "transparent"
    border.width: 1
    border.color: activeFocus ? root.accent : (kfMouse.containsMouse ? root.foreground : root.muted)
    activeFocusOnTab: true
    onActiveFocusChanged: root.editorFocus = activeFocus

    PlainText {
      id: kfText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: kf.text !== "" ? kf.text + (kf.activeFocus ? "▏" : "") : (kf.activeFocus ? "▏" : kf.placeholderText)
      color: kf.text !== "" ? root.foreground : root.muted
      font.pixelSize: Style.font.caption
      elide: Text.ElideLeft
    }

    MouseArea {
      id: kfMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.IBeamCursor
      onClicked: kf.forceActiveFocus()
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { kf.accepted(); event.accepted = true; return }
      if (event.key === Qt.Key_Escape) { kf.escaped(); event.accepted = true; return }
      if (event.key === Qt.Key_Backspace) { kf.edited(kf.text.slice(0, -1)); event.accepted = true; return }
      if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
      var t = event.text
      if (t.length === 1 && kf.allowed.test(t) && kf.text.length < kf.maximumLength) {
        kf.edited(kf.text + t)
        event.accepted = true
      }
    }
  }

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

  component DetailMessage: PlainText {
    required property var result
    width: parent.width
    visible: text !== ""
    text: !result || result.loading ? "Loading…" : result.error || ""
    color: root.muted
    wrapMode: Text.Wrap
  }

  component NamedAction: Row {
    id: named
    property string placeholder
    property string verb
    property string target
    property var prefix: []
    property string draft: ""
    property string storageKey: ""
    readonly property string fieldValue: storageKey ? (root.drafts[storageKey] || "") : draft
    function store(value) {
      if (storageKey) root.setMap("drafts", storageKey, value || false)
      else draft = value
    }
    property string buttonText: "Save"
    signal submitted()
    spacing: Style.space(6)
    function submit() {
      if (!Model.validName(fieldValue) || root.pending[target]) return
      root.runAction(verb, prefix.concat([fieldValue]), target)
      store("")
      submitted()
    }
    KeyField {
      width: Math.max(80, named.width - saveNamed.implicitWidth - named.spacing)
      text: named.fieldValue
      placeholderText: named.placeholder
      onEdited: function(v) { named.store(v) }
      onAccepted: named.submit()
    }
    ActionButton {
      id: saveNamed
      text: named.buttonText
      enabled: Model.validName(named.fieldValue) && !root.pending[named.target]
      onClicked: named.submit()
    }
  }

  component EgressCard: Column {
    id: egress
    required property string box
    readonly property string detailKey: "egress:" + box
    readonly property var result: root.details[detailKey]
    readonly property var policy: result && result.ok ? result.data : null
    readonly property bool busy: !!root.pending[detailKey]
    readonly property bool canEdit: !!policy && !busy
      && !(root.exitOn && (!root.exitBoxes.length || root.exitBoxes.indexOf(box) >= 0))
    readonly property string entry: root.drafts[detailKey] || ""
    spacing: Style.space(6)
    Row {
      spacing: Style.space(6)
      PlainText { text: egress.policy ? "Egress · " + (egress.policy.mode === "blocked" ? "Allowlist only" : "Open by default") : "Egress" }
      ActionButton { text: "Refresh"; enabled: !egress.busy; onClicked: root.loadDetail("egress", egress.box) }
    }
    DetailMessage { result: egress.result }
    PlainText {
      width: parent.width
      visible: !!egress.policy
      text: "Rules carry over to forks and snapshots. Egress rules and an exit node cannot be used together."
      color: root.muted
      wrapMode: Text.Wrap
    }
    Repeater {
      model: egress.policy ? egress.policy.rules : []
      delegate: Row {
        required property var modelData
        width: egress.width
        spacing: Style.space(6)
        PlainText { width: Math.max(80, parent.width - removeRule.implicitWidth - parent.spacing); text: parent.modelData.kind + "  " + parent.modelData.entry }
        ActionButton {
          id: removeRule
          text: "Remove"
          enabled: egress.canEdit
          onClicked: root.request("net-rm", egress.box, [egress.box, parent.modelData.entry], parent.modelData.kind + " " + parent.modelData.entry)
        }
      }
    }
    KeyField {
      visible: !!egress.policy
      enabled: egress.canEdit
      width: parent.width
      maximumLength: 255
      allowed: /[A-Za-z0-9.*\/-]/
      placeholderText: "Domain, wildcard, IPv4 or CIDR"
      text: egress.entry
      onEdited: function(v) { root.setMap("drafts", egress.detailKey, v || false) }
    }
    Flow {
      visible: !!egress.policy
      width: parent.width
      spacing: Style.space(6)
      ActionButton { text: "Allow"; enabled: egress.canEdit && !!egress.entry; onClicked: root.request("net-allow", egress.box, [egress.box, egress.entry], egress.entry) }
      ActionButton { text: "Deny"; enabled: egress.canEdit && !!egress.entry; onClicked: root.request("net-deny", egress.box, [egress.box, egress.entry], egress.entry) }
      ActionButton { text: "Allowlist only"; enabled: egress.canEdit && egress.policy.mode === "open"; onClicked: root.request("net-block", egress.box) }
      ActionButton { text: "Clear rules and reopen"; enabled: egress.canEdit && (egress.policy.mode === "blocked" || egress.policy.rules.length > 0); onClicked: root.request("net-open", egress.box) }
    }
  }

  component NetworksCard: Column {
    id: networks
    readonly property var result: root.details.networks
    readonly property bool busy: !!root.pending.networks
    property string joining: ""
    spacing: Style.space(6)
    Row {
      spacing: Style.space(6)
      PlainText { text: "Private networks" }
      ActionButton { text: "Refresh"; enabled: !networks.busy; onClicked: root.loadDetail("networks", "") }
    }
    DetailMessage { result: networks.result }
    PlainText {
      visible: !!networks.result && networks.result.ok && networks.result.data.length === 0
      text: "No private networks yet."
      color: root.muted
    }
    PlainText {
      visible: !!networks.result && networks.result.ok
      width: parent.width
      text: "Forks inherit membership. Connecting to a suspended member can wake it."
      color: root.muted
      wrapMode: Text.Wrap
    }
    NamedAction {
      visible: !!networks.result && networks.result.ok
      width: parent.width
      placeholder: "Network name"
      buttonText: "Create network"
      verb: "net-create"
      target: "networks"
    }
    Repeater {
      model: networks.result && networks.result.ok ? networks.result.data : []
      delegate: Column {
        id: network
        required property var modelData
        width: networks.width
        spacing: Style.space(4)
        PlainText { width: parent.width; text: network.modelData.name + "  ·  " + network.modelData.cidr; font.bold: true }
        Repeater {
          model: network.modelData.members
          delegate: Column {
            id: member
            required property var modelData
            width: network.width
            PlainText { width: parent.width; text: root.boxLabel(member.modelData.box) + "  ·  " + member.modelData.ip }
            PlainText { width: parent.width; text: member.modelData.host; color: root.muted }
            ActionButton {
              text: "Remove member"
              enabled: !networks.busy
              onClicked: root.request("net-leave", network.modelData.name, [network.modelData.name, member.modelData.box], root.boxLabel(member.modelData.box))
            }
          }
        }
        Row {
          spacing: Style.space(6)
          ActionButton {
            text: "Add a box"
            enabled: !networks.busy
            active: networks.joining === network.modelData.name
            onClicked: networks.joining = active ? "" : network.modelData.name
          }
          ActionButton {
            text: "Delete network"
            enabled: !networks.busy
            onClicked: root.request("net-delete", network.modelData.name, [network.modelData.name],
              network.modelData.members.map(function(m) { return root.boxLabel(m.box) }).join(", "))
          }
        }
        Flow {
          visible: networks.joining === network.modelData.name
          width: parent.width
          spacing: Style.space(5)
          Repeater {
            model: root.boxes.filter(function(b) {
              for (var i = 0; i < network.modelData.members.length; ++i)
                if (network.modelData.members[i].box === b.name) return false
              return true
            })
            delegate: ActionButton {
              required property var modelData
              text: root.boxLabel(modelData.name)
              enabled: !networks.busy
              onClicked: {
                networks.joining = ""
                root.runAction("net-join", [network.modelData.name, modelData.name], "networks")
              }
            }
          }
        }
      }
    }
  }

  component SecretsCard: Column {
    id: secrets
    readonly property var result: root.details.secrets
    readonly property bool busy: !!root.pending.secrets
    property bool editing: false
    property bool replacing: false
    property bool advanced: false
    property string secretName: ""
    property string host: ""
    property string header: "Authorization"
    property string format: "Bearer {}"
    property bool allBoxes: false
    property bool intercept: false
    property var selected: []
    readonly property var missingBoxes: selected.filter(function(name) {
      return !root.boxes.some(function(box) { return box.name === name })
    })
    readonly property bool nameExists: !!result && !!result.ok && result.data.some(function(item) {
      return item.name === secrets.secretName
    })
    spacing: Style.space(6)
    function edit(item) {
      secretName = item ? item.name : ""
      host = item && item.hosts.length === 1 ? item.hosts[0] : ""
      allBoxes = !!(item && item.all)
      selected = item ? item.boxes.slice() : []
      header = "Authorization"
      format = "Bearer {}"
      intercept = false
      replacing = !!item
      advanced = replacing
      editing = true
    }
    Row {
      spacing: Style.space(6)
      PlainText { text: "Managed secrets" }
      ActionButton { text: "Refresh"; enabled: !secrets.busy; onClicked: root.loadDetail("secrets", "") }
      ActionButton { text: "Add secret"; enabled: !!secrets.result && secrets.result.ok && !secrets.busy; onClicked: secrets.edit(null) }
    }
    DetailMessage { result: secrets.result }
    PlainText {
      visible: !!secrets.result && secrets.result.ok && secrets.result.data.length === 0
      text: "No managed secrets yet."
      color: root.muted
    }
    Repeater {
      model: secrets.result && secrets.result.ok ? secrets.result.data : []
      delegate: Column {
        id: savedSecret
        required property var modelData
        width: secrets.width
        spacing: Style.space(4)
        PlainText { width: parent.width; text: savedSecret.modelData.name; font.bold: true }
        PlainText {
          width: parent.width
          text: savedSecret.modelData.hosts.join(", ") + "  ·  "
            + (savedSecret.modelData.all ? "All boxes" : savedSecret.modelData.boxes.map(function(b) { return root.boxLabel(b) }).join(", "))
          wrapMode: Text.Wrap
          color: root.muted
        }
        Row {
          spacing: Style.space(6)
          ActionButton { text: "Replace value or scope"; enabled: !secrets.busy; onClicked: secrets.edit(savedSecret.modelData) }
          ActionButton { text: "Remove"; enabled: !secrets.busy; onClicked: root.request("secret-rm", savedSecret.modelData.name) }
        }
      }
    }
    Column {
      visible: secrets.editing && !!secrets.result && secrets.result.ok
      width: parent.width
      spacing: Style.space(5)
      PlainText {
        width: parent.width
        text: secrets.replacing
          ? "Review the header, format, and interception choice before replacing this secret. Orble lists only its name, host, and scope."
          : "Choose a destination and scope, then enter the value in Orble’s terminal prompt."
        color: root.muted
        wrapMode: Text.Wrap
      }
      KeyField {
        width: parent.width
        enabled: !secrets.replacing
        placeholderText: "SECRET_NAME"
        allowed: /[A-Z0-9_]/
        text: secrets.secretName
        onEdited: function(v) { secrets.secretName = v }
      }
      KeyField {
        width: parent.width
        maximumLength: 253
        allowed: /[A-Za-z0-9.-]/
        placeholderText: "Destination host (api.example.com)"
        text: secrets.host
        onEdited: function(v) { secrets.host = v }
      }
      Flow {
        width: parent.width
        spacing: Style.space(5)
        ActionButton { text: "All boxes"; active: secrets.allBoxes; onClicked: secrets.allBoxes = !secrets.allBoxes }
        Repeater {
          model: secrets.allBoxes ? [] : root.boxes
          delegate: ActionButton {
            required property var modelData
            text: root.boxLabel(modelData.name)
            active: secrets.selected.indexOf(modelData.name) >= 0
            onClicked: secrets.selected = Model.toggled(secrets.selected, modelData.name)
          }
        }
      }
      PlainText {
        visible: !secrets.replacing && secrets.nameExists
        text: "This name already exists. Choose Replace on its row."
        color: root.urgent
        width: parent.width
        wrapMode: Text.Wrap
      }
      Repeater {
        model: secrets.allBoxes ? [] : secrets.missingBoxes
        delegate: ActionButton {
          required property string modelData
          text: "Remove unavailable box " + modelData
          onClicked: secrets.selected = Model.toggled(secrets.selected, modelData)
        }
      }
      ActionButton { text: "HTTP header and interception"; active: secrets.advanced; onClicked: secrets.advanced = !secrets.advanced }
      KeyField {
        visible: secrets.advanced
        width: parent.width
        placeholderText: "HTTP header"
        text: secrets.header
        onEdited: function(v) { secrets.header = v }
      }
      KeyField {
        visible: secrets.advanced
        width: parent.width
        maximumLength: 100
        allowed: /[ -~]/
        placeholderText: "Header format (Bearer {})"
        text: secrets.format
        onEdited: function(v) { secrets.format = v }
      }
      ActionButton { visible: secrets.advanced; text: "HTTPS interception"; active: secrets.intercept; onClicked: secrets.intercept = !secrets.intercept }
      Row {
        spacing: Style.space(6)
        ActionButton { text: "Cancel"; onClicked: secrets.editing = false }
        ActionButton {
          text: "Enter value in terminal"
          enabled: !secrets.busy && /^[A-Z_][A-Z0-9_]*$/.test(secrets.secretName)
            && /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]+$/.test(secrets.host)
            && /^[A-Za-z][A-Za-z0-9-]{0,63}$/.test(secrets.header)
            && secrets.format.split("{}").length === 2
            && (secrets.replacing || !secrets.nameExists)
            && (secrets.allBoxes || (secrets.selected.length > 0 && !secrets.missingBoxes.length))
          onClicked: root.submitSecret(secrets.secretName, secrets.host, secrets.header, secrets.format,
            secrets.allBoxes, secrets.intercept, secrets.selected, secrets.replacing)
        }
      }
    }
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
    readonly property bool renameOpen: root.renameBox === brow.b.name
    readonly property bool egressOpen: root.egressBox === brow.b.name
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
            text: root.boxLabel(brow.b.name)
                  + (brow.b.keepAwake === true ? "  " + Model.icons.coffee : "")
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
        text: Model.detailLine(brow.b, brow.b.keepAwake === true)
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
          readonly property bool on: brow.b.keepAwake === true
          visible: root.keepAwakeCli
          iconText: Model.icons.coffee; text: on ? "Let it sleep" : "Keep awake"
          tooltipText: on ? "orble keep-awake off: it suspends when idle again"
                          : "orble keep-awake: Orble keeps it running when idle, even with this machine off (billed while running)"
          onClicked: root.toggleAwake(brow.b)
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

      Flow {
        width: parent.innerWidth
        spacing: Style.space(6)
        enabled: !brow.isBusy
        ActionButton { visible: root.modernCli; text: "Rename"; active: brow.renameOpen; onClicked: root.renameBox = brow.renameOpen ? "" : brow.b.name }
        Repeater {
          model: !root.modernCli ? [] : brow.b.size === "s" ? ["m", "l"] : brow.b.size === "m" ? ["l"] : []
          delegate: ActionButton {
            required property string modelData
            text: "Resize to " + modelData.toUpperCase()
            onClicked: root.request("resize", brow.b.name, [brow.b.name, modelData], modelData)
          }
        }
        ActionButton {
          text: "Egress rules"
          active: brow.egressOpen
          onClicked: root.toggleEgress(brow.b.name)
        }
      }
      NamedAction {
        visible: brow.renameOpen
        width: parent.innerWidth
        placeholder: "New box name"
        verb: "rename"
        target: brow.b.name
        prefix: [brow.b.name]
        storageKey: "rename:" + brow.b.name
        onSubmitted: root.renameBox = ""
      }
      EgressCard { visible: brow.egressOpen; width: parent.innerWidth; box: brow.b.name }

      // Save a snapshot: optional name, then Save.
      Row {
        visible: root.snapFor === brow.b.name && !brow.isBusy
        spacing: Style.space(6)

        KeyField {
          id: snapField
          width: Style.space(170)
          anchors.verticalCenter: parent.verticalCenter
          placeholderText: "name (optional)"
          text: root.snapName
          maximumLength: 63
          onEdited: function(v) { root.snapName = v }
          onAccepted: root.saveSnapshot(brow.b.name)
          onEscaped: { root.snapFor = ""; keyCatcher.forceActiveFocus() }
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

        KeyField {
          id: portField
          width: Style.space(80)
          anchors.verticalCenter: parent.verticalCenter
          placeholderText: "port"
          text: root.expandedBox === brow.b.name ? root.portInput : ""
          maximumLength: 5
          allowed: /[0-9]/
          onEdited: function(v) { root.portInput = v }
          onAccepted: root.sharePort(brow.b.name, root.portInput, false)
          onEscaped: { root.portInput = ""; keyCatcher.forceActiveFocus() }
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
      anchors.right: pprivate.visible ? pprivate.left : poff.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.copy
      tooltipText: "Copy the address"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.copyText(prow.p.url)
    }

    PanelActionButton {
      id: pprivate
      visible: root.modernCli && prow.p.access === "public"
      anchors.right: poff.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.icons.lock
      tooltipText: "Make this shared port private"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !prow.busyVerb
      onClicked: root.runAction("port-private", [prow.box, String(prow.p.port)], "port:" + prow.box + ":" + prow.p.port)
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
    readonly property bool renameOpen: root.renameSnapshot === srow.sn.name
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
          text: srow.sn.alias || srow.sn.name
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        PlainText {
          width: parent.width
          text: srow.busyVerb ? Model.progressText[srow.busyVerb] + "…" : (srow.sn.gallery ? "Gallery · " : "") + Model.snapshotLine(srow.sn)
          color: root.muted
          font.pixelSize: Style.font.caption
        }
      }

      PanelActionButton {
        id: snew
        anchors.right: srename.visible ? srename.left : srm.visible ? srm.left : parent.right
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
        id: srename
        visible: root.modernCli && !srow.sn.gallery
        anchors.right: srm.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: "✎"
        tooltipText: "Rename snapshot"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !srow.busyVerb
        onClicked: root.renameSnapshot = srow.renameOpen ? "" : srow.sn.name
      }
      PanelActionButton {
        id: srm
        visible: !srow.sn.gallery
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

    NamedAction {
      visible: srow.renameOpen && !srow.sn.gallery
      width: parent.width
      placeholder: "New snapshot name"
      verb: "snapshot-rename"
      target: "snap:" + srow.sn.name
      prefix: [srow.sn.name]
      storageKey: "snapshot-rename:" + srow.sn.name
      onSubmitted: root.renameSnapshot = ""
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
