// Tests Model.js (a QML ".pragma library" file) under Node: node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
import vm from "node:vm"

const src = readFileSync(fileURLToPath(new URL("../Model.js", import.meta.url)), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(src + "\n;Object.assign(M, { glyph, icons, validName, validFingerprint, parseStatus, isRunning, runningCount, stateLabel, stateTone, hasDesktop, size, money, subline, detailLine, sshCommand, shortFingerprint, headline, tooltip, creditLow, topupOptions, sizeOptions, sizeLabel, confirmText, confirmButton, exitNodeArgs, toggled, cleanLine, exitSummary, ago, progressText })", { M, Date, JSON, Math, String, Number, Object, Array, isNaN })

let n = 0
const t = (name, fn) => { fn(); n++ }
const FP = "SHA256:VqNeCT+Csoh6KEj7S5ozLdD2IKPKx/Pg0n9KFt4NVTc"

t("validName and fingerprints", () => {
  for (const ok of ["rku7", "a", "box-1.2_x", "A".repeat(63)]) assert.ok(M.validName(ok), ok)
  for (const bad of ["", "-x", "--help", ".x", "a b", "a;b", "$(id)", "A".repeat(64), null, undefined]) assert.ok(!M.validName(bad), String(bad))
  assert.ok(M.validFingerprint(FP))
  for (const bad of ["", "SHA256:short", "MD5:" + "a".repeat(43), FP + "x", "-y"]) assert.ok(!M.validFingerprint(bad), bad)
})

t("parseStatus", () => {
  assert.equal(M.parseStatus("not json"), null)
  assert.equal(M.parseStatus(""), null)
  const s = M.parseStatus('{"ok":true}')
  assert.deepEqual([s.boxes.length, s.keys.length, s.localKeys.length, s.viewer], [0, 0, 0, ""])
})

t("states", () => {
  const s = { boxes: [{ state: "running" }, { state: "suspended" }, { state: "running" }] }
  assert.equal(M.runningCount(s), 2)
  assert.equal(M.runningCount(null), 0)
  assert.equal(M.stateLabel({ state: "suspended" }), "Suspended")
  assert.equal(M.stateLabel({}), "Unknown")
  assert.equal(M.stateTone({ state: "running" }), "on")
  assert.equal(M.stateTone({ state: "resuming" }), "busy")
  assert.equal(M.stateTone({ state: "suspending" }), "busy")
  assert.equal(M.stateTone({ state: "failed" }), "bad")
  assert.equal(M.stateTone({ state: "suspended" }), "off")
  assert.ok(M.hasDesktop({ flags: ["desktop"] }))
  assert.ok(!M.hasDesktop({ flags: [] }) && !M.hasDesktop({}) && !M.hasDesktop({ flags: "desktop" }))
  // QML hands stored arrays back as array-like list wrappers, not real Arrays.
  assert.ok(M.hasDesktop({ flags: { length: 1, 0: "desktop" } }))
})

t("formatting", () => {
  assert.equal(M.money(5), "$5.00")
  assert.equal(M.money(0.0031), "$0.0031")
  assert.equal(M.money(0), "$0.00")
  assert.equal(M.money(150.4), "$150")
  assert.equal(M.money(-2), "-$2.00")
  const b = { name: "rku7", state: "suspended", vcpus: 2, memGiB: 4, spentUSD: 0.0031, active: "30h ago", flags: ["desktop"], host: "rku7.z.orble.tech" }
  assert.equal(M.size(b), "2 vCPU · 4 GB")
  assert.equal(M.subline(b, ""), "Suspended · 2 vCPU · 4 GB · $0.0031 spent")
  assert.equal(M.subline(b, "resume"), "Resuming… · 2 vCPU · 4 GB · $0.0031 spent")
  assert.equal(M.detailLine(b), "active 30h ago · desktop on")
  assert.equal(M.detailLine(b, true), "active 30h ago · desktop on · kept awake")
  assert.equal(M.detailLine({ flags: [] }, true), "kept awake")
  assert.equal(M.sshCommand(b), "orble ssh rku7")
  assert.equal(M.sshCommand({ name: "x", host: "" }), "orble ssh x")
  assert.equal(M.sshCommand({ name: "--help", host: "h" }), "")
  assert.equal(M.shortFingerprint(FP), "SHA256:VqNeCT+…NVTc")
  const now = 1_000_000
  assert.equal(M.ago(now, now - 30), "just now")
  assert.equal(M.ago(now, now - 3600), "1h ago")
  assert.equal(M.ago(now, 0), "")
})

t("headline, tooltip, credit", () => {
  const s = { ok: true, boxes: [{}, {}], account: { creditUSD: 5 } }
  assert.equal(M.headline(s, 1), "1 running · 2 boxes")
  assert.equal(M.headline({ ok: true, boxes: [{}] }, 0), "0 running · 1 box")
  assert.equal(M.headline({ ok: false, authError: true }, 0), "Not signed in")
  assert.equal(M.headline({ ok: false }, 0), "Can't reach Orble")
  assert.equal(M.headline(null, 0), "Loading…")
  assert.equal(M.tooltip(s, 1, false), "Orble: 1 of 2 boxes running\n$5.00 credit")
  assert.match(M.tooltip(s, 1, true), /Exit node on$/)
  assert.ok(M.creditLow({ creditUSD: 0.5 }, 1))
  assert.ok(!M.creditLow({ creditUSD: 5 }, 1))
  assert.ok(!M.creditLow({ creditUSD: 0.5 }, 0))
  assert.ok(!M.creditLow({ creditUSD: null }, 1) && !M.creditLow(null, 1))
  for (const o of M.topupOptions) assert.ok(+o.value >= 10 && +o.value <= 500, o.value)
})

t("confirm texts", () => {
  assert.match(M.confirmText("rm", "rku7"), /rku7.*gone for good/)
  assert.match(M.confirmText("keys-rm", "laptop"), /laptop/)
  assert.match(M.confirmText("topup", "$25"), /\$25.*terminal/)
  assert.match(M.confirmText("fork", "rku7"), /Fork rku7.*billed/)
  assert.equal(M.confirmButton("fork"), "Fork")
  assert.equal(M.sizeOptions.map(o => o.value).join(","), "s,m,l")
  assert.equal(M.sizeLabel("m"), "M · 4/8")
  assert.equal(M.sizeLabel("xl"), "")
  assert.equal(M.confirmButton("rm"), "Delete")
  assert.equal(M.confirmButton("topup"), "Continue")
  for (const v of ["suspend", "resume", "rm", "vnc", "desktop-off", "new", "keys-add", "keys-rm", "update", "fork"]) assert.ok(M.progressText[v], v)
})

t("exit node", () => {
  assert.deepEqual([...M.exitNodeArgs({ boxes: [], lan: false, fallback: false })], [])
  assert.deepEqual([...M.exitNodeArgs({ boxes: ["a", "b"], lan: true, fallback: true })], ["--lan", "--fallback", "a", "b"])
  assert.deepEqual([...M.exitNodeArgs({ boxes: ["a", "-x", "a", "$(id)"], lan: false, fallback: false })], ["a"])
  assert.deepEqual([...M.toggled(["a"], "b")], ["a", "b"])
  assert.deepEqual([...M.toggled(["a", "b"], "a")], ["b"])
  assert.equal(M.cleanLine("\x1b[32m✓\x1b[0m Exit node connected\r\n"), "✓ Exit node connected")
  assert.equal(M.cleanLine("x".repeat(200)).length, 161)
  assert.equal(M.exitSummary(false, {}, ""), "Off")
  assert.equal(M.exitSummary(true, { boxes: ["a"], lan: true }, ""), "On for a · LAN")
  assert.match(M.exitSummary(true, { boxes: [] }, ""), /dashboard/)
})

t("icons are single code points", () => {
  for (const [k, v] of Object.entries(M.icons)) assert.equal([...v].length, 1, k)
})

console.log(`model-test: ${n} groups passed`)
