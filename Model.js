.pragma library

// Pure helpers for the Orble panel: parsing, formatting, labels.

function glyph(cp) { return String.fromCodePoint(cp) }

var icons = {
  server: glyph(0xF048B),
  ssh: glyph(0xF018D),
  play: glyph(0xF040A),
  pause: glyph(0xF03E4),
  trash: glyph(0xF01B4),
  refresh: glyph(0xF0450),
  plus: glyph(0xF0415),
  fork: glyph(0xF0641),
  copy: glyph(0xF018F),
  cash: glyph(0xF0114),
  link: glyph(0xF0339),
  check: glyph(0xF012C),
  close: glyph(0xF0156),
  earth: glyph(0xF01E7),
  lan: glyph(0xF0317),
  key: glyph(0xF0306),
  monitor: glyph(0xF0379),
  update: glyph(0xF06B0),
  login: glyph(0xF0342),
  coffee: glyph(0xF0176),
  camera: glyph(0xF0100),
  share: glyph(0xF0496),
  open: glyph(0xF03CC),
  lock: glyph(0xF033E)
}

var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
var FP_RE = /^SHA256:[A-Za-z0-9+\/]{43}$/

function validName(name) { return NAME_RE.test(String(name || "")) }
function validFingerprint(fp) { return FP_RE.test(String(fp || "")) }

// A port to share: whole number 1 to 65535, as text from the field.
function validPort(p) {
  p = String(p || "").trim()
  return /^\d{1,5}$/.test(p) && Number(p) >= 1 && Number(p) <= 65535
}

// Snapshot names go to the CLI as an argument too; empty lets the CLI pick one.
function validSnapshotName(n) { n = String(n || "").trim(); return n === "" || validName(n) }

function parseStatus(text) {
  try {
    var d = JSON.parse(String(text || ""))
    if (!d || typeof d !== "object") return null
    if (!Array.isArray(d.boxes)) d.boxes = []
    if (!Array.isArray(d.keys)) d.keys = []
    if (!Array.isArray(d.localKeys)) d.localKeys = []
    if (!Array.isArray(d.snapshots)) d.snapshots = []
    d.snapshotsSupported = d.snapshotsSupported === true
    if (typeof d.viewer !== "string") d.viewer = ""
    return d
  } catch (e) {
    return null
  }
}

function isRunning(b) { return b && b.state === "running" }

function runningCount(status) {
  if (!status) return 0
  var n = 0
  for (var i = 0; i < status.boxes.length; i++) if (isRunning(status.boxes[i])) n++
  return n
}

function stateLabel(b) {
  var st = String(b && b.state || "")
  return st ? st.charAt(0).toUpperCase() + st.slice(1) : "Unknown"
}

// "on" lit, "off" dim, "busy" transitional, "bad" error
function stateTone(b) {
  var st = String(b && b.state || "")
  if (st === "running") return "on"
  if (/error|fail/.test(st)) return "bad"
  if (/ing$/.test(st)) return "busy"
  return "off"
}

// Flags as a plain array. Once QML stores status in a `property var`, its arrays come back as
// list wrappers that fail Array.isArray, so copy by index instead.
function flagsOf(b) {
  var out = []
  var f = b ? b.flags : null
  if (f && typeof f !== "string" && f.length) for (var i = 0; i < f.length && i < 8; i++) out.push(String(f[i]))
  return out
}

function hasDesktop(b) { return flagsOf(b).indexOf("desktop") >= 0 }

function size(b) {
  var parts = []
  if (b.vcpus) parts.push(b.vcpus + " vCPU")
  if (b.memGiB) parts.push(b.memGiB + " GB")
  return parts.join(" · ")
}

// Box spend is tiny (per-second billing), so small amounts keep four decimals.
function money(v) {
  v = Number(v) || 0
  var a = Math.abs(v)
  if (a > 0 && a < 0.01) return (v < 0 ? "-$" : "$") + a.toFixed(4)
  return (v < 0 ? "-$" : "$") + (a >= 100 ? Math.round(a) : a.toFixed(2))
}

function subline(b, verb) {
  var parts = [verb ? progressText[verb] + "…" : stateLabel(b)]
  var sz = size(b)
  if (sz) parts.push(sz)
  parts.push(money(b.spentUSD) + " spent")
  return parts.join(" · ")
}

function detailLine(b, awake) {
  var parts = []
  if (b.forkedFrom) parts.push("fork of " + b.forkedFrom)
  if (b.diskGiB) parts.push(b.diskGiB + " GB disk")
  if (b.active) parts.push("active " + b.active)
  if (hasDesktop(b)) parts.push("desktop on")
  flagsOf(b).forEach(function(f) { if (f !== "desktop") parts.push(f) })
  if (awake) parts.push("kept awake")
  return parts.join(" · ")
}

// Always `orble ssh`: boxes are IPv6-only, so a plain `ssh <host>` fails on
// IPv4-only networks, and the CLI routes the connection either way.
function sshCommand(b) {
  return b && validName(b.name) ? "orble ssh " + b.name : ""
}

function shortFingerprint(fp) {
  fp = String(fp || "")
  return fp.length > 20 ? fp.slice(0, 14) + "…" + fp.slice(-4) : fp
}

function headline(status, running) {
  if (!status) return "Loading…"
  if (!status.ok) return status.authError ? "Not signed in" : "Can't reach Orble"
  var total = status.boxes.length
  return running + " running · " + total + (total === 1 ? " box" : " boxes")
}

function tooltip(status, running, exitOn) {
  if (!status) return "Orble"
  if (!status.ok) return "Orble: " + (status.authError ? "not signed in" : "unreachable")
  var t = "Orble: " + running + " of " + status.boxes.length + " boxes running"
  if (status.account && status.account.creditUSD !== null && status.account.creditUSD !== undefined)
    t += "\n" + money(status.account.creditUSD) + " credit"
  if (exitOn) t += "\nExit node on"
  return t
}

function creditLow(account, threshold) {
  if (!account || account.creditUSD === null || account.creditUSD === undefined) return false
  return account.creditUSD < (Number(threshold) || 0)
}

// orble new -s: s 2 vCPU 4 GiB (the CLI's default), m 4/8, l 8/16. Prices from
// orble.tech/pricing (2026-11-16): per second while running, nothing while suspended.
var sizeOptions = [
  { value: "s", label: "S · 2/4", hourUSD: 0.015 },
  { value: "m", label: "M · 4/8", hourUSD: 0.03 },
  { value: "l", label: "L · 8/16", hourUSD: 0.06 }
]

function sizeOption(v) {
  for (var i = 0; i < sizeOptions.length; i++) if (sizeOptions[i].value === v) return sizeOptions[i]
  return null
}

// "Create M box" for the button; the tooltip has the price.
function createLabel(v) {
  var o = sizeOption(v)
  return o ? "Create " + o.value.toUpperCase() + " box" : "Create"
}

function sizeTooltip(v) {
  var o = sizeOption(v)
  if (!o) return "orble new"
  var p = o.label.split(" · ")[1].split("/")
  return "orble new -s " + o.value + ": " + p[0] + " vCPU, " + p[1] + " GiB, 64 GiB disk · $" + o.hourUSD + "/h while running, $0 suspended"
}

// Sizes a box made from this snapshot can have: its own, or larger (files only, no running programs).
function sizesFrom(snap) {
  var c = Number(snap && snap.vcpus) || 0
  return sizeOptions.filter(function(o) { return Number(o.label.split(" · ")[1].split("/")[0]) >= c })
}

function snapshotSize(snap) {
  var o = sizeOption(snap && snap.size)
  return o ? o.label : size(snap || {})
}

function snapshotLine(snap) {
  var parts = []
  if (snap.box) parts.push("from " + snap.box)
  var sz = snapshotSize(snap)
  if (sz) parts.push(sz)
  if (snap.disk) parts.push(snap.disk)
  if (snap.created) parts.push(snap.created)
  if (snap.state && snap.state !== "ready") parts.push(snap.state)
  return parts.join(" · ")
}

// "Create M box" for a snapshot; a larger size than the snapshot's gets its files only.
function fromTooltip(snap, v) {
  var same = snap && (snap.size === v || !snap.size)
  return "orble new --from " + (snap ? snap.name : "") + " -s " + v + ": "
    + (same ? "its files and running programs" : "larger than the snapshot, so its files only")
    + " · " + sizeTooltip(v).split(" · ")[1]
}

function portAccess(p) {
  return p && p.access === "public" ? "anyone with the address" : "your Orble account only"
}

function sizeLabel(v) {
  var o = sizeOption(v)
  return o ? o.label : ""
}

var topupOptions = [
  { value: "10", label: "$10" }, { value: "25", label: "$25" },
  { value: "50", label: "$50" }, { value: "100", label: "$100" }
]

function confirmText(verb, target, extra) {
  switch (verb) {
  case "rm": return "Delete box " + target + "? Its disk and everything on it are gone for good."
  case "keys-rm": return "Remove SSH key " + target + " from your Orble account? New boxes won't accept it."
  case "fork": return "Fork " + target + " into a new box? It carries on from " + target + ", running programs included, and is billed like any box."
  case "snapshot-rm": return "Delete snapshot " + target + "? Boxes made from it keep running; the snapshot itself is gone for good."
  case "port-public": return "Share port " + target + " publicly? Anyone with the address can reach it, no sign-in needed."
  case "topup": return "Add " + target + " of Orble credit? orble topup opens in a terminal; follow it there to pay."
  default: return verb + " " + target + "?"
  }
}

function confirmButton(verb) {
  if (verb === "rm") return "Delete"
  if (verb === "keys-rm") return "Remove"
  if (verb === "topup") return "Continue"
  if (verb === "fork") return "Fork"
  if (verb === "snapshot-rm") return "Delete"
  if (verb === "port-public") return "Share"
  return "Confirm"
}

// argv tail for `orble-panel exit-node` from the card's options.
function exitNodeArgs(opts) {
  var args = []
  if (opts.lan) args.push("--lan")
  if (opts.fallback) args.push("--fallback")
  ;(opts.boxes || []).forEach(function(b) { if (validName(b) && args.indexOf(b) < 0) args.push(b) })
  return args
}

function toggled(list, item) {
  var out = (list || []).slice()
  var i = out.indexOf(item)
  if (i >= 0) out.splice(i, 1)
  else out.push(item)
  return out
}

// One line of exit-node output, safe to show: no escapes or control characters, bounded.
function cleanLine(s) {
  s = String(s || "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/[\x00-\x1f\x7f]/g, " ").trim()
  return s.length > 160 ? s.slice(0, 160) + "…" : s
}

function exitSummary(on, opts, line) {
  if (!on) return line ? line : "Off"
  var who = opts.boxes && opts.boxes.length ? opts.boxes.join(", ") : "boxes switched on in the dashboard"
  var extra = []
  if (opts.lan) extra.push("LAN")
  if (opts.fallback) extra.push("fallback")
  return "On for " + who + (extra.length ? " · " + extra.join(", ") : "")
}

function ago(nowSec, thenSec) {
  if (!thenSec) return ""
  var d = Math.max(0, nowSec - thenSec)
  if (d < 60) return "just now"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

var progressText = {
  "suspend": "Suspending", "resume": "Resuming", "rm": "Deleting", "vnc": "Opening desktop",
  "desktop-off": "Turning desktop off", "new": "Creating", "keys-add": "Adding", "keys-rm": "Removing",
  "update": "Updating", "fork": "Forking", "snapshot": "Saving snapshot", "snapshot-rm": "Deleting",
  "new-from": "Creating", "port": "Sharing", "port-public": "Sharing", "port-off": "Unsharing"
}
