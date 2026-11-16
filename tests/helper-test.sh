#!/usr/bin/env bash
# Tests bin/orble-panel against a fake `orble` CLI and a fake notifier.
# Needs bash, python3 and ssh-keygen; touches no real account.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/bin/orble-panel"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.ssh" "$T/config/orble"
LOG="$T/calls.log"
NOTES="$T/notes.log"
export FAKE_PIDS="$T/ssh.pids" FAKE_LOG="$LOG" FAKE_NOTES="$NOTES" FAKE_MODE=ok HOME="$T/home" XDG_CONFIG_HOME="$T/config"
echo '{"api":"https://orble.tech","token":"fake-token","domain":"zippy-summit"}' > "$T/config/orble/config.json"

# Two local keys: one already on the account (the fake prints its fingerprint), one not.
ssh-keygen -q -t ed25519 -N "" -C "on@account" -f "$T/home/.ssh/id_on"
ssh-keygen -q -t ed25519 -N "" -C "new@laptop" -f "$T/home/.ssh/id_new"
FP_ON=$(ssh-keygen -lf "$T/home/.ssh/id_on.pub" | awk '{print $2}')
export FP_ON
ln -s /etc/hostname "$T/home/.ssh/evil.pub"

cat > "$T/bin/orble" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ $FAKE_MODE == auth ]]; then
  echo "Not signed in yet. Signing in first."; echo "Opening https://orble.tech/cli?code=AAAA-BBBB"; sleep 30; exit 0
fi
case "$*" in
  ls\ --json) [[ -n ${FAKE_JSON:-} ]] || exit 0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s' '[{"name":"base1","hostname":"base1.zippy-summit.orble.tech","state":"running","desktop":true,"vcpus":4,"mem_mib":8192,"disk_gib":64,"spent_micros":1250000,"last_active_at":"'"$now"'"},
      {"name":"other","hostname":"evil.example.com","state":"suspended","desktop":false,"vcpus":"x","mem_mib":4096,"spent_micros":0,"last_active_at":"2020-01-01T00:00:00Z"},
      {"name":"kid2","hostname":"kid2.zippy-summit.orble.tech","state":"running","vcpus":2,"mem_mib":4096,"forked_from":"kid1"},
      {"name":"-rf","hostname":"x.zippy-summit.orble.tech","state":"running"},
      {"name":"kid1","hostname":"kid1.zippy-summit.orble.tech","state":"Running!","vcpus":8,"mem_mib":16384,"forked_from":{"name":"base1"}}]' ;;
  ls) [[ -n ${FAKE_EMPTY:-} ]] && { echo "No boxes yet. Create one: orble new"; exit 0; }
    printf '%s\n' \
    'NAME     STATE          HOST                             SIZE     SPENT    ACTIVE   ' \
    'rku7     ◐ suspended    rku7.zippy-summit.orble.tech     s 2c/4g  $0.0031  30h ago  desktop' \
    'k7f2     ● running      k7f2.zippy-summit.orble.tech     4c/8g    $1.25    now      ' \
    'big1     ● running      big1.zippy-summit.orble.tech     l 8c/16g $0.10    2m ago   ' \
    '-rf      ● running      evil.example.com                 s 2c/4g  $0.00    now      ' \
    'x$(id)   ● running      x.zippy-summit.orble.tech        s 2c/4g  $0.00    now      ' ;;
  account)
    printf 'agent@example.com\n  boxes   <box>.zippy-summit.orble.tech\n  credit  $%s\n  keys    1\n' "${FAKE_CREDIT:-5.00}" ;;
  keys) printf 'omarchy-yoga  %s\n' "$FP_ON" ;;
  new|new\ -s\ *) echo "✓ k9zz ready in 0.21s" ;;
  fork\ *) echo "✓ rku7-f1 ready in 0.40s"; echo "✓ rku7-f2 ready in 0.42s" ;;
  update) echo "✓ Orble is up to date 515f19f2" ;;
  snapshots\ --json) [[ -n ${FAKE_OLD_CLI:-} ]] && { echo "Orble · Sandboxes for AI agents"; exit 0; }
    printf '%s' '[{"name":"plugin-test","box":"nvbg","state":"ready","vcpus":4,"mem_mib":8192,"disk_bytes":409100288,"created_at":"2026-11-16T17:24:45Z"},
      {"name":"-y","box":"nvbg","state":"ready"},
      {"name":"big","box":"$(id)","state":"Saving!","vcpus":8,"mem_mib":16384,"disk_bytes":2500000000}]' ;;
  snapshot\ nvbg*) echo "✓ saved nvbg as plugin-test m 4c/8g, 409 MB, in 1.13s"; echo "  orble new --from plugin-test" ;;
  snapshot\ rm\ *) echo "✓ deleted snapshot ${3}" ;;
  new\ --from\ *) echo "✓ q2w3 ready in 0.30s" ;;
  port\ nvbg) printf '%s\n' '8080   signin  https://8080-yj3vcxk7lezdtgpc.orble.dev' \
    '3000   public  https://3000-yj3vcxk7lezdtgpc.orble.dev' '9999   signin  https://evil.example.com' '99999  signin  https://x.orble.dev' ;;
  port\ rku7) echo "no shared ports" ;;
  port\ nvbg\ 8081\ --public) echo "orble: public ports are for accounts that have added credit: https://orble.tech/dashboard" >&2; exit 1 ;;
  port\ nvbg\ *\ --off) echo "✓ nvbg:${3} unshared" ;;
  port\ nvbg\ *) echo "✓ nvbg:${3} signin"; echo "  https://${3}-yj3vcxk7lezdtgpc.orble.dev" ;;
  rm\ broken*) echo "orble: no such box" >&2; exit 1 ;;
  ssh\ *--\ sleep\ infinity) [[ -n ${FAKE_SSH_DROP:-} ]] && { echo "Connection closed by remote host" >&2; exit 255; }
    echo $$ >> "$FAKE_PIDS"; exec sleep 30 ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/bin/omarchy-notification-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NOTES"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# --- status: table parsing, unsafe rows dropped, keys matched ---
out=$("$HELPER" status)
python3 -I - "$out" <<'EOF' || fail "status shape"
import json, os, sys
d = json.loads(sys.argv[1])
assert d["ok"] is True and d["error"] == "", d
b = {x["name"]: x for x in d["boxes"]}
assert sorted(b) == ["big1", "k7f2", "rku7"], sorted(b)
r = b["rku7"]
assert r["state"] == "suspended" and r["host"] == "rku7.zippy-summit.orble.tech"
assert r["size"] == "s" and b["k7f2"]["size"] == "" and (b["big1"]["size"], b["big1"]["vcpus"], b["big1"]["memGiB"]) == ("l", 8, 16), b
assert (r["vcpus"], r["memGiB"], r["spentUSD"], r["active"], r["flags"]) == (2, 4, 0.0031, "30h ago", ["desktop"]), r
k = b["k7f2"]
assert k["state"] == "running" and k["vcpus"] == 4 and k["spentUSD"] == 1.25 and k["flags"] == [] and k["active"] == "now"
a = d["account"]
assert a == {"email": "agent@example.com", "domain": "zippy-summit", "creditUSD": 5.0, "keys": 1}, a
assert d["keys"] == [{"name": "omarchy-yoga", "fingerprint": os.environ["FP_ON"]}]
lk = {x["file"]: x for x in d["localKeys"]}
assert sorted(lk) == ["id_new.pub", "id_on.pub"], sorted(lk)
assert lk["id_on.pub"]["added"] is True and lk["id_new.pub"]["added"] is False
assert lk["id_new.pub"]["comment"] == "new@laptop" and lk["id_new.pub"]["type"] == "ED25519"
assert d["viewer"] in ("", "xtigervncviewer", "remmina")
EOF
ok

# --- status from ls --json: fields, fork order, unsafe values dropped ---
out=$(FAKE_JSON=1 "$HELPER" status)
python3 -I - "$out" <<'EOF' || fail "json status"
import json, sys
d = json.loads(sys.argv[1])
b = d["boxes"]
assert [x["name"] for x in b] == ["base1", "kid1", "kid2", "other"], [x["name"] for x in b]
assert [x["depth"] for x in b] == [0, 1, 2, 0], b
x = b[0]
assert (x["size"], x["vcpus"], x["memGiB"], x["diskGiB"], x["spentUSD"], x["active"], x["flags"]) == ("m", 4, 8, 64, 1.25, "now", ["desktop"]), x
assert b[1]["forkedFrom"] == "base1" and b[1]["size"] == "l" and b[1]["state"] == "unknown"
assert b[2]["forkedFrom"] == "kid1" and b[2]["size"] == "s"
o = b[3]
assert o["host"] == "" and o["vcpus"] == 0 and o["size"] == "" and o["active"].endswith("d ago") and o["flags"] == []
EOF
ok

# --- snapshots in status: fields, unsafe rows dropped; a CLI without snapshots ---
out=$("$HELPER" status)
python3 -I - "$out" <<'EOF' || fail "snapshots in status"
import json, sys
d = json.loads(sys.argv[1])
assert d["snapshotsSupported"] is True
sn = d["snapshots"]
assert [x["name"] for x in sn] == ["plugin-test", "big"], sn
assert sn[0] == {"name": "plugin-test", "box": "nvbg", "state": "ready", "size": "m", "vcpus": 4, "memGiB": 8,
                 "disk": "409 MB", "created": sn[0]["created"]} and sn[0]["created"].endswith("ago"), sn[0]
assert sn[1]["box"] == "" and sn[1]["state"] == "unknown" and sn[1]["size"] == "l" and sn[1]["disk"] == "2.5 GB", sn[1]
EOF
out=$(FAKE_OLD_CLI=1 "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["snapshotsSupported"] is False and d["snapshots"] == []' "$out" || fail "old CLI snapshots"
ok

# --- ports: parsed, unsafe rows dropped ---
out=$("$HELPER" ports nvbg)
python3 -I - "$out" <<'EOF' || fail "ports"
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] and d["box"] == "nvbg"
assert d["ports"] == [{"port": 8080, "access": "signin", "url": "https://8080-yj3vcxk7lezdtgpc.orble.dev"},
                      {"port": 3000, "access": "public", "url": "https://3000-yj3vcxk7lezdtgpc.orble.dev"}], d
EOF
[[ $("$HELPER" ports rku7) == '{"ok": true, "error": "", "box": "rku7", "ports": []}' ]] || fail "no ports"
ok

# --- no boxes yet ---
out=$(FAKE_EMPTY=1 "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is True and d["boxes"] == [] and d["account"]["creditUSD"] == 5.0' "$out" || fail "empty box list"
ok

# --- signed out: no CLI call at all, and a sign-in prompt from the CLI is cut short ---
: > "$LOG"
mv "$T/config/orble/config.json" "$T/config/orble/config.off"
out=$("$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is False and d["authError"] is True' "$out" || fail "signed-out status"
[[ ! -s $LOG ]] || fail "CLI ran while signed out: $(cat "$LOG")"
set +e; "$HELPER" action suspend rku7 >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 3 && ! -s $LOG ]] || fail "action ran while signed out (code $code)"
mv "$T/config/orble/config.off" "$T/config/orble/config.json"
start=$(date +%s)
out=$(FAKE_MODE=auth "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is False and d["authError"] is True' "$out" || fail "expired sign-in reported"
(( $(date +%s) - start < 10 )) || fail "sign-in prompt was not cut short"
ok

# --- actions build the right argv ---
: > "$LOG"; : > "$NOTES"
"$HELPER" action suspend rku7
"$HELPER" action resume rku7
"$HELPER" action rm rku7
"$HELPER" action vnc rku7
"$HELPER" action desktop-off rku7
"$HELPER" action keys-add id_new.pub
"$HELPER" action keys-rm "$FP_ON"
"$HELPER" action update
"$HELPER" action new
"$HELPER" action new m
"$HELPER" action fork rku7
"$HELPER" action fork rku7 2
"$HELPER" action snapshot nvbg
"$HELPER" action snapshot nvbg plugin-test
"$HELPER" action snapshot-rm plugin-test
"$HELPER" action new-from plugin-test
"$HELPER" action new-from plugin-test l
"$HELPER" action port nvbg 8080
"$HELPER" action port-off nvbg 8080
"$HELPER" action port-public nvbg 8082
expected="suspend rku7
resume rku7
rm rku7 -y
vnc rku7
desktop rku7 --off
keys add $T/home/.ssh/id_new.pub
keys rm $FP_ON
update
account
new
account
new -s m
account
fork rku7 -n 1
account
fork rku7 -n 2
snapshot nvbg
snapshot nvbg plugin-test
snapshot rm plugin-test -y
account
new --from plugin-test
account
new --from plugin-test -s l
port nvbg 8080
port nvbg 8080 --off
port nvbg 8082 --public"
[[ $(cat "$LOG") == "$expected" ]] || { diff <(echo "$expected") "$LOG"; fail "action argv"; }
ok
[[ $(wc -l < "$NOTES") -eq 20 ]] || fail "one notification per action ($(wc -l < "$NOTES"))"
grep -q "Saved nvbg as plugin-test m 4c/8g, 409 MB, in 1.13s" "$NOTES" || fail "snapshot notification"
grep -q "Snapshot plugin-test deleted" "$NOTES" || fail "snapshot rm notification"
grep -q "q2w3 ready in 0.30s" "$NOTES" || fail "new --from notification"
grep -q "nvbg:8080 shared: https://8080-yj3vcxk7lezdtgpc.orble.dev" "$NOTES" || fail "port notification"
grep -q "nvbg:8082 shared (anyone with the address): https://8082-" "$NOTES" || fail "public port notification"
grep -q "nvbg:8080 unshared" "$NOTES" || fail "port off notification"
grep -q "k9zz ready in 0.21s" "$NOTES" || fail "new box name in the notification"
grep -q "up to date" "$NOTES" || fail "update notification"
grep -q "Forked rku7 → rku7-f1, rku7-f2" "$NOTES" || fail "fork names in the notification"
ok

# --- no credit: new is refused before orble new could offer a top-up ---
: > "$LOG"; : > "$NOTES"
set +e; FAKE_CREDIT=0.00 "$HELPER" action new >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 5 && $(cat "$LOG") == "account" ]] || fail "new with no credit (code $code, calls: $(cat "$LOG"))"
grep -q "no credit" "$NOTES" || fail "no-credit notification"
: > "$LOG"
set +e; FAKE_CREDIT=0.00 "$HELPER" action new-from plugin-test >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 5 && $(cat "$LOG") == "account" ]] || fail "new --from with no credit (code $code)"
: > "$LOG"
set +e; FAKE_CREDIT=0.00 "$HELPER" action fork rku7 >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 5 && $(cat "$LOG") == "account" ]] || fail "fork with no credit (code $code)"
ok

# --- failures notify urgently and keep the exit code ---
: > "$NOTES"
set +e; "$HELPER" action rm broken >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 1 ]] || fail "exit code passed through (got $code)"
grep -q -- "-u critical" "$NOTES" && grep -q "no such box" "$NOTES" || fail "failure notification"
ok

# --- a refused public port reports the CLI's reason ---
: > "$NOTES"
set +e; "$HELPER" action port-public nvbg 8081 >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 1 ]] && grep -q "added credit" "$NOTES" || fail "public port refusal"
ok

# --- unsafe input is refused before the CLI runs ---
: > "$LOG"
refuse() { if "$HELPER" "$@" >/dev/null 2>&1 </dev/null; then fail "accepted: $*"; fi; }
for bad in 'a;b' '-rf' '--help' '$(id)' '' 'x y' "$(printf 'a%.0s' {1..70})"; do
  refuse action rm "$bad"
  refuse action suspend "$bad"
  refuse ssh "$bad"
  refuse desktop "$bad"
  refuse exit-node "$bad"
  refuse action fork "$bad"
  refuse action snapshot "$bad"
  refuse action snapshot nvbg "$bad"
  refuse action snapshot-rm "$bad"
  refuse action new-from "$bad"
  refuse action port "$bad" 8080
  refuse ports "$bad"
done
for bad in 0 65536 -1 80a 8.0 --off '' 123456; do
  refuse action port nvbg "$bad"
  refuse action port-public nvbg "$bad"
  refuse action port-off nvbg "$bad"
done
refuse action port nvbg
refuse action port nvbg 80 81
refuse action snapshot nvbg a b
refuse action snapshot-rm
refuse action snapshot-rm a b
refuse action new-from plugin-test xl
refuse action new-from plugin-test s m
refuse ports
refuse ports a b
refuse action new xl
refuse action new -s
refuse action new s m
refuse action fork rku7 0
refuse action fork rku7 11
refuse action fork rku7 -n
refuse action fork rku7 1 2
refuse action fork
refuse action rm
refuse action rm a b
refuse action new extra
refuse action update now
refuse action ssh-everything rku7
refuse action topup 25
refuse action keys-add ../.bashrc
refuse action keys-add /etc/passwd
refuse action keys-add evil.pub
refuse action keys-add missing.pub
refuse action keys-add id_new
refuse action keys-rm 'SHA256:short'
refuse action keys-rm '-y'
refuse topup 5
refuse topup 501
refuse topup 25.5
refuse topup '$(id)'
refuse exit-node --lan --lan
refuse exit-node rku7 rku7
refuse exit-node --everything
refuse login now
[[ ! -s $LOG ]] || fail "CLI ran for refused input: $(cat "$LOG")"
ok

# --- terminal commands pass the right argv (no tty: they return at once) ---
: > "$LOG"
"$HELPER" ssh rku7 < /dev/null > /dev/null
"$HELPER" topup 25 < /dev/null > /dev/null
"$HELPER" login < /dev/null > /dev/null
[[ $(cat "$LOG") == $'ssh rku7\ntopup 25\nlogin' ]] || { cat "$LOG"; fail "terminal argv"; }
ok

# --- exit-node becomes orble exit-node with the validated flags ---
: > "$LOG"
"$HELPER" exit-node --lan --fallback rku7 k7f2 > /dev/null
"$HELPER" exit-node > /dev/null
[[ $(cat "$LOG") == $'exit-node --lan --fallback rku7 k7f2\nexit-node' ]] || { cat "$LOG"; fail "exit-node argv"; }
ok

# --- keep-awake: one idle orble ssh per box, ended by SIGTERM ---
refuse keep-awake
refuse keep-awake rku7 rku7
refuse keep-awake --help
refuse keep-awake 'x$(id)'
: > "$LOG"
"$HELPER" keep-awake rku7 k7f2 > "$T/awake.out" & pid=$!
sleep 1.5; kill -TERM $pid; wait $pid || fail "keep-awake exit code"
want='-o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes -- sleep infinity'
[[ $(sort "$LOG") == "ssh k7f2 $want"$'\n'"ssh rku7 $want" ]] || { cat "$LOG"; fail "keep-awake argv"; }
grep -q "Keeping rku7, k7f2 awake" "$T/awake.out" && grep -q "Stopped" "$T/awake.out" || { cat "$T/awake.out"; fail "keep-awake output"; }
for p in $(cat "$T/ssh.pids"); do ! kill -0 "$p" 2>/dev/null || fail "keep-awake left session $p running"; done
ok

# --- keep-awake reconnects a dropped session ---
: > "$LOG"
FAKE_SSH_DROP=1 ORBLE_PANEL_RETRY_SEC=1 "$HELPER" keep-awake rku7 > "$T/awake.out" & pid=$!
sleep 2.8; kill -TERM $pid; wait $pid || true
(( $(grep -c '^ssh rku7' "$LOG") >= 2 )) || { cat "$LOG"; fail "keep-awake did not reconnect"; }
grep -q "session ended (Connection closed by remote host)" "$T/awake.out" || { cat "$T/awake.out"; fail "keep-awake drop message"; }
ok

# --- keep-awake stops at a sign-in prompt, and never starts signed out ---
: > "$LOG"; : > "$NOTES"
set +e; FAKE_MODE=auth timeout 10 "$HELPER" keep-awake rku7 > "$T/awake.out"; code=$?; set -e
[[ $code == 3 ]] || fail "keep-awake at a sign-in prompt exited $code"
grep -q "keep awake stopped" "$NOTES" || fail "keep-awake sign-in notification"
mv "$T/config/orble/config.json" "$T/config.json"; : > "$LOG"
set +e; "$HELPER" keep-awake rku7 > /dev/null; code=$?; set -e
mv "$T/config.json" "$T/config/orble/config.json"
[[ $code == 3 && ! -s $LOG ]] || fail "keep-awake signed out: exit $code, calls: $(cat "$LOG")"
ok

# --- demo data: valid shapes, and the CLI is never called ---
: > "$LOG"
out=$("$HELPER" status --demo)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["demo"] and len(d["boxes"])==3 and d["account"]["creditUSD"]>0 and d["localKeys"] and d["snapshots"]' "$out" || fail "demo status"
"$HELPER" ports k7f2 --demo | grep -q '"port": 3000' || fail "demo ports"
"$HELPER" exit-node k7f2 --demo > "$T/exit.out" & pid=$!
sleep 0.5; kill -INT $pid; wait $pid
grep -q "connected" "$T/exit.out" && grep -q "off" "$T/exit.out" || fail "demo exit node"
"$HELPER" keep-awake k7f2 --demo > "$T/awake.out" & pid=$!
sleep 0.5; kill -TERM $pid; wait $pid
grep -q "Keeping k7f2 awake" "$T/awake.out" && grep -q "Stopped" "$T/awake.out" || fail "demo keep awake"
[[ ! -s $LOG ]] || fail "demo mode called the CLI: $(cat "$LOG")"
ok

echo "helper-test: $pass groups passed"
