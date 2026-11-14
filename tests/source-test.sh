#!/usr/bin/env bash
# Static checks on the QML and helper sources.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

# Every Text in the panel must be plain text, because box and key names and
# CLI output reach the UI (see Omarchy's "Plugin UI Safety").
bare=$(grep -nE '^\s*Text\s*\{' "$ROOT/Panel.qml" || true)
[[ -z $bare ]] || fail "bare Text element (use PlainText):\n$bare"
grep -q 'component PlainText: Text {' "$ROOT/Panel.qml" || fail "PlainText component missing"
grep -A1 'component PlainText: Text {' "$ROOT/Panel.qml" | grep -q 'textFormat: Text.PlainText' || fail "PlainText is not plain"

# Processes are started with argv arrays, never a shell string with data in it.
if grep -nE '"(ba)?sh",\s*"-c"' "$ROOT/Panel.qml"; then fail "shell -c in Panel.qml"; fi
grep -q 'shell=True' "$ROOT/bin/orble-panel" && fail "shell=True in helper"

# URLs opened from the panel must be https.
grep -q 'if (/\^https:' "$ROOT/Panel.qml" || fail "openUrl https guard missing"

# The manifest is valid JSON with the fields Omarchy needs.
python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
assert m["id"] == "thelaggingway.orble-helper"
assert m["kinds"] == ["bar-widget"] and m["entryPoints"]["barWidget"] == "Panel.qml"
for f in m["barWidget"]["schema"]:
    assert f["key"] in m["barWidget"]["defaults"], f["key"]
' "$ROOT/manifest.json" || fail "manifest"

# Destructive and paying verbs stay behind the confirm dialog.
line=$(grep 'readonly property var confirmVerbs' "$ROOT/Panel.qml") || fail "confirmVerbs missing"
for v in rm keys-rm topup; do
  [[ $line == *"\"$v\""* ]] || fail "confirmVerbs lacks $v"
done

# Top-ups only ever run in a visible terminal, never as a background action.
grep -q '"topup"' <(sed -n '/^ONE_ARG = {/,/^}/p' "$ROOT/bin/orble-panel") && fail "topup must not be a background action"

# Demo mode never acts on the account.
[[ $(grep -c 'if (root.demo) { demoNotice(); return }' "$ROOT/Panel.qml") -ge 2 ]] || fail "demo guard must cover runAction and openTerminal"

# The exit node is stopped the way Ctrl-C stops it.
grep -q 'exitProc.signal(2)' "$ROOT/Panel.qml" || fail "exit node must stop with SIGINT"

# The helper only checks that a sign-in exists; it never prints or passes on the token.
grep -q 'bool(d.get("token"))' "$ROOT/bin/orble-panel" || fail "signed_in check changed"
[[ $(grep -c '"token"' "$ROOT/bin/orble-panel") -eq 1 ]] || fail "token used outside signed_in()"

[[ -x $ROOT/bin/orble-panel ]] || fail "bin/orble-panel is not executable"
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROOT/bin/orble-panel" || fail "helper syntax"

echo "source-test: ok"
