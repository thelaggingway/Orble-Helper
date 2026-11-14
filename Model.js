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
  login: glyph(0xF0342)
}

var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
var FP_RE = /^SHA256:[A-Za-z0-9+\/]{43}$/

function validName(name) { return NAME_RE.test(String(name || "")) }
function validFingerprint(fp) { return FP_RE.test(String(fp || "")) }

function parseStatus(text) {
  try {
    var d = JSON.parse(String(text || ""))
    if (!d || typeof d !== "object") return null
    if (!Array.isArray(d.boxes)) d.boxes = []
    if (!Array.isArray(d.keys)) d.keys = []
    if (!Array.isArray(d.localKeys)) d.localKeys = []
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

function detailLine(b) {
  var parts = []
  if (b.active) parts.push("active " + b.active)
  if (hasDesktop(b)) parts.push("desktop on")
  flagsOf(b).forEach(function(f) { if (f !== "desktop") parts.push(f) })
  return parts.join(" · ")
}

function sshCommand(b) {
  return b && b.host ? "ssh " + b.host : "orble ssh " + (b ? b.name : "")
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

var topupOptions = [
  { value: "10", label: "$10" }, { value: "25", label: "$25" },
  { value: "50", label: "$50" }, { value: "100", label: "$100" }
]

function confirmText(verb, target, extra) {
  switch (verb) {
  case "rm": return "Delete box " + target + "? Its disk and everything on it are gone for good."
  case "keys-rm": return "Remove SSH key " + target + " from your Orble account? New boxes won't accept it."
  case "topup": return "Add " + target + " of Orble credit? orble topup opens in a terminal; follow it there to pay."
  default: return verb + " " + target + "?"
  }
}

function confirmButton(verb) {
  if (verb === "rm") return "Delete"
  if (verb === "keys-rm") return "Remove"
  if (verb === "topup") return "Continue"
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
  "update": "Updating"
}
