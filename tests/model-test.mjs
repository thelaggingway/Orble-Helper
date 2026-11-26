// Tests Model.js (a QML ".pragma library" file) under Node: node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
import vm from "node:vm"

const src = readFileSync(fileURLToPath(new URL("../Model.js", import.meta.url)), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(src + "\n;Object.assign(M, { glyph, icons, validName, validFingerprint, parseStatus, isRunning, isStopped, runningCount, stateLabel, stateTone, hasDesktop, size, money, subline, detailLine, sshCommand, shortFingerprint, headline, tooltip, creditLow, topupOptions, sizeOptions, sizeLabel, sizeOption, createLabel, sizeTooltip, confirmText, confirmButton, exitNodeArgs, toggled, cleanLine, exitSummary, ago, progressText, validPort, validSnapshotName, sizesFrom, snapshotLine, fromTooltip, portAccess, validProject, validProjectName, activeProject, projectLabel, validHosts })", { M, Date, JSON, Math, String, Number, Object, Array, isNaN })

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
  assert.ok(M.isStopped({ state: "stopped" }) && !M.isStopped({ state: "suspended" }))
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
  assert.equal(M.sizeOptions.map(o => o.value).join(","), "micro,s,m,l")
  assert.equal(M.sizeLabel("micro"), "μ · 1/2")
  assert.equal(M.sizeLabel("m"), "M · 4/8")
  assert.equal(M.sizeLabel("xl"), "")
  assert.equal(M.createLabel("micro"), "Create Micro box")
  assert.equal(M.createLabel("m"), "Create M box")
  assert.equal(M.createLabel("xl"), "Create")
  assert.match(M.sizeTooltip("l"), /-s l: 8 vCPU, 16 GiB.*\$0\.06\/h/)
  assert.match(M.confirmText("fork", "rku7"), /running programs/)
  assert.match(M.detailLine({ forkedFrom: "base1", diskGiB: 64, flags: [] }, false), /^fork of base1 · 64 GB disk/)
  assert.equal(M.confirmButton("rm"), "Delete")
  assert.equal(M.confirmButton("topup"), "Continue")
  assert.match(M.confirmText("secret-copy", "GH_TOKEN", "Client"), /Copy GH_TOKEN.*to project Client/)
  assert.equal(M.confirmButton("secret-copy"), "Copy")
  assert.match(M.confirmText("logout", "Orble"), /Sign the Orble CLI out/)
  assert.equal(M.confirmButton("logout"), "Sign out")
  for (const v of ["suspend", "resume", "start", "rm", "vnc", "desktop-off", "new", "keys-add", "keys-rm", "update", "logout", "fork", "secret-copy"]) assert.ok(M.progressText[v], v)
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

t("ports", () => {
  for (const ok of ["1", "80", "8080", "65535", " 3000 "]) assert.ok(M.validPort(ok), ok)
  for (const bad of ["", "0", "65536", "-1", "80a", "8.0", "--off", null]) assert.ok(!M.validPort(bad), String(bad))
  assert.equal(M.portAccess({ access: "public" }), "anyone with the address")
  assert.equal(M.portAccess({ access: "token" }), "anyone with the preview token")
  assert.equal(M.portAccess({ access: "signin" }), "your Orble account only")
  assert.match(M.confirmText("port-public", "nvbg:8080"), /nvbg:8080.*Anyone/)
  assert.equal(M.confirmButton("port-public"), "Share")
  assert.match(M.confirmText("port-token", "nvbg:3000"), /preview token/)
  assert.equal(M.confirmButton("port-token"), "Share")
  assert.match(M.confirmText("port-new-token", "nvbg:3000"), /old token stops working/)
  assert.equal(M.confirmButton("port-new-token"), "Replace")
})

t("snapshots", () => {
  assert.ok(M.validSnapshotName("") && M.validSnapshotName("plugin-test") && M.validSnapshotName(" x1 "))
  for (const bad of ["-y", "a b", "$(id)", "--help"]) assert.ok(!M.validSnapshotName(bad), bad)
  const sn = { name: "plugin-test", box: "nvbg", state: "ready", size: "m", vcpus: 4, memGiB: 8, disk: "409 MB", created: "now" }
  assert.equal(M.snapshotLine(sn), "from nvbg · M · 4/8 · 409 MB · now")
  assert.equal(M.snapshotLine({ ...sn, state: "saving" }), "from nvbg · M · 4/8 · 409 MB · now · saving")
  assert.deepEqual(Array.from(M.sizesFrom(sn), o => o.value), ["m", "l"])
  assert.deepEqual(Array.from(M.sizesFrom({ vcpus: 2 }), o => o.value), ["s", "m", "l"])
  assert.deepEqual(Array.from(M.sizesFrom({ vcpus: 1 }), o => o.value), ["micro", "s", "m", "l"])
  assert.match(M.fromTooltip(sn, "m"), /--from plugin-test -s m: its files and running programs/)
  assert.match(M.fromTooltip(sn, "l"), /files only/)
  assert.match(M.confirmText("snapshot-rm", "plugin-test"), /plugin-test.*gone for good/)
  assert.equal(M.progressText["new-from"], "Creating")
  const st = M.parseStatus('{"ok":true,"snapshots":[{"name":"a"}],"snapshotsSupported":true}')
  assert.equal(st.snapshots.length, 1)
  assert.equal(st.snapshotsSupported, true)
  assert.equal(M.parseStatus('{"ok":true}').snapshotsSupported, false)
})

t("projects", () => {
  for (const ok of ["default", "client-work", "a1"]) assert.ok(M.validProject(ok), ok)
  for (const bad of ["", "Default", "-rf", "a b", "a/b", "a".repeat(64), null]) assert.ok(!M.validProject(bad), String(bad))
  assert.ok(M.validProjectName("Client work 2") && !M.validProjectName(" x") && !M.validProjectName("a$(id)") && !M.validProjectName("x".repeat(41)))
  const list = [{ slug: "personal", name: "Personal" }, { slug: "default", name: "Default" }]
  // Picked, then the helper's ORBLE_PROJECT, then "default" when listed, then the first listed.
  assert.equal(M.activeProject("personal", { project: "other" }, list), "personal")
  assert.equal(M.activeProject("", { project: "other" }, list), "other")
  assert.equal(M.activeProject("", { project: "" }, list), "default")
  assert.equal(M.activeProject("", null, [{ slug: "main", name: "Main" }]), "main")
  assert.equal(M.activeProject("", null, []), "")
  assert.equal(M.projectLabel("personal", list), "Personal")
  assert.equal(M.projectLabel("gone", list), "gone")
  assert.equal(M.projectLabel("", []), "Default")
  const st = M.parseStatus('{"ok":true}')
  assert.deepEqual([st.projects.length, st.project], [0, ""])
  assert.match(M.confirmText("secret-rm", "GH_TOKEN", "Personal"), /GH_TOKEN from the Personal project/)
  assert.match(M.confirmText("project-create", "Client"), /Create the Orble project Client\?.*no command to delete/)
})

t("secret hosts, gallery and snapshot sources", () => {
  for (const ok of ["api.example.com", "api.github.com,github.com,uploads.github.com"]) assert.ok(M.validHosts(ok), ok)
  for (const bad of ["", "example", "a.com,", ",a.com", "a.com,a.com", "a.com b.com", "-x.com", "a.com;id"]) assert.ok(!M.validHosts(bad), bad)
  assert.equal(M.snapshotLine({ gallery: true, about: "for E2B's desktop SDK", size: "s" }), "for E2B's desktop SDK · S · 2/4")
  assert.equal(M.snapshotLine({ gallery: true, size: "s" }), "Orble gallery · S · 2/4")
  assert.equal(M.detailLine({ fromSnapshot: "amp-orb-base", diskGiB: 64 }, false), "from snapshot amp-orb-base · 64 GB disk")
})

console.log(`model-test: ${n} groups passed`)
