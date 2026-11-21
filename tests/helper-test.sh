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
unset ORBLE_API_KEY ORBLE_PROJECT
export FAKE_LOG="$LOG" FAKE_NOTES="$NOTES" FAKE_MODE=ok HOME="$T/home" XDG_CONFIG_HOME="$T/config"
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
if [[ ${1:-} == --project ]]; then
  # Like the real CLI, project list still works when the picked project is gone.
  [[ $2 == nope && $3 != project && $3 != --help ]] && { echo "orble: Project not found." >&2; exit 1; }
  shift 2
fi
if [[ $FAKE_MODE == auth ]]; then
  echo "Not signed in yet. Signing in first."; echo "Opening https://orble.tech/cli?code=AAAA-BBBB"; sleep 30; exit 0
fi
case "$*" in
  ls\ --json) [[ -n ${FAKE_JSON:-} ]] || exit 0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s' '[{"name":"base1","hostname":"base1.zippy-summit.orble.tech","state":"running","desktop":true,"vcpus":4,"mem_mib":8192,"disk_gib":64,"spent_micros":1250000,"last_active_at":"'"$now"'","keep_awake":true},
      {"name":"other","hostname":"evil.example.com","state":"suspended","desktop":false,"keep_awake":"yes","vcpus":"x","mem_mib":4096,"spent_micros":0,"last_active_at":"2020-01-01T00:00:00Z"},
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
    printf '%s' '[{"name":"plugin-test","alias":"renamed-snapshot","box":"nvbg","state":"ready","vcpus":4,"mem_mib":8192,"disk_bytes":409100288,"created_at":"2026-11-16T17:24:45Z"},
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
  net\ rku7) printf 'blocked\nallow  example.com\ndeny   192.0.2.1\n' ;;
  net\ ls)
    if [[ ${FAKE_DETAILS:-} == old ]]; then echo 'Orble · Sandboxes for AI agents' >&2; exit 2; fi
    if [[ ${FAKE_DETAILS:-} == free ]]; then echo 'orble: box networks require Pro' >&2; exit 1; fi
    if [[ ${FAKE_DETAILS:-} == malformed ]]; then echo 'unknown output'; exit 0; fi
    printf 'my-net  10.240.0.0/24\n  10.240.0.2       rku7.my-net.internal\n' ;;
  secret\ ls) [[ -n ${FAKE_SECRETS:-} ]] && { printf '%b' "$FAKE_SECRETS"; exit 0; }
    printf '%s\n' 'EXAMPLE_KEY  example.com  rku7, base1' \
      'GH_TOKEN  api.github.com,github.com,uploads.github.com  all boxes in project  intercept' \
      'SCOPED_ONE  api.example.com  rku7  intercept' ;;
  project\ list) printf 'default  Default\nclient-work  Client work\n-rf  Evil\n' ;;
  project\ create\ *) echo "✓ created project ${3}" ;;
  rm\ broken*) echo "orble: no such box" >&2; exit 1 ;;
  --help) printf 'Orble · Sandboxes for AI agents\n\n  resize <box> <m|l>     restart a box at a larger size\n'
    [[ -n ${FAKE_OLD_CLI:-} ]] || printf '  project list | create <name>  List projects or create one\n'
    [[ -n ${FAKE_OLD_CLI:-} ]] || printf "  keep-awake <box> [off]  don't suspend when idle; off undoes it\n" ;;
  keep-awake\ *) [[ -n ${FAKE_OLD_CLI:-} ]] && { echo "Orble · Sandboxes for AI agents"; exit 0; }
    [[ $3 == off ]] && echo "$2  ● running, suspends when idle" || echo "$2  ● running, kept awake" ;;
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
assert x["keepAwake"] is True and [y["keepAwake"] for y in b[1:]] == [False, False, False], b
assert d["keepAwakeSupported"] is True and d["modernCli"] is True, d
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
assert sn[0] == {"name": "plugin-test", "alias": "renamed-snapshot", "gallery": False, "about": "", "box": "nvbg", "state": "ready", "size": "m", "vcpus": 4, "memGiB": 8,
                 "disk": "409 MB", "created": sn[0]["created"]} and sn[0]["created"].endswith("ago"), sn[0]
assert sn[1]["box"] == "" and sn[1]["state"] == "unknown" and sn[1]["size"] == "l" and sn[1]["disk"] == "2.5 GB", sn[1]
EOF
out=$(FAKE_OLD_CLI=1 "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["snapshotsSupported"] is False and d["snapshots"] == [] and d["keepAwakeSupported"] is False' "$out" || fail "old CLI snapshots"
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
# The CLI also signs in with ORBLE_API_KEY and no stored login.
out=$(ORBLE_API_KEY=orble_fake "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is True' "$out" || fail "ORBLE_API_KEY sign-in"
: > "$LOG"
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

# --- keep-awake: the server-side pin, on and off; an old CLI's help is a failure ---
refuse action keep-awake --help
refuse action keep-awake 'x$(id)'
refuse action keep-awake rku7 k7f2
refuse action keep-awake-off
: > "$LOG"; : > "$NOTES"
"$HELPER" action keep-awake rku7
"$HELPER" action keep-awake-off rku7
[[ $(cat "$LOG") == $'keep-awake rku7\nkeep-awake rku7 off' ]] || { cat "$LOG"; fail "keep-awake argv"; }
grep -q "rku7 kept awake" "$NOTES" && grep -q "rku7 suspends when idle again" "$NOTES" || { cat "$NOTES"; fail "keep-awake notifications"; }
: > "$NOTES"
set +e; FAKE_OLD_CLI=1 "$HELPER" action keep-awake rku7; code=$?; set -e
[[ $code == 2 ]] && grep -q "keep-awake failed.*Update" "$NOTES" || { cat "$NOTES"; fail "old CLI keep-awake exited $code"; }
ok

# --- demo data: valid shapes, and the CLI is never called ---
: > "$LOG"
out=$("$HELPER" status --demo)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["demo"] and len(d["boxes"])==3 and d["account"]["creditUSD"]>0 and d["localKeys"] and d["snapshots"] and [b["keepAwake"] for b in d["boxes"]]==[False,True,False]' "$out" || fail "demo status"
"$HELPER" ports k7f2 --demo | grep -q '"port": 3000' || fail "demo ports"
"$HELPER" exit-node k7f2 --demo > "$T/exit.out" & pid=$!
sleep 0.5; kill -INT $pid; wait $pid
grep -q "connected" "$T/exit.out" && grep -q "off" "$T/exit.out" || fail "demo exit node"
[[ ! -s $LOG ]] || fail "demo mode called the CLI: $(cat "$LOG")"
ok

# --- On-demand Pro data and fixed arguments ---
"$HELPER" detail egress rku7 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["mode"]=="blocked" and len(d["data"]["rules"])==2'
"$HELPER" detail networks | python3 -c 'import json,sys; assert json.load(sys.stdin)["data"][0]["members"][0]["box"]=="rku7"'
"$HELPER" detail secrets | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d[0] == {"name": "EXAMPLE_KEY", "hosts": ["example.com"], "boxes": ["rku7", "base1"], "all": False, "intercept": False}, d[0]
assert d[1] == {"name": "GH_TOKEN", "hosts": ["api.github.com", "github.com", "uploads.github.com"], "boxes": [], "all": True, "intercept": True}, d[1]
assert d[2]["boxes"] == ["rku7"] and d[2]["intercept"] is True and not d[2]["all"], d[2]
'
for bad in 'KEY  example.com  rku7  bogus' 'KEY  example.com  $(id)' 'KEY  evil host  all boxes in project' 'KEY  example.com'; do
  FAKE_SECRETS="$bad\n" "$HELPER" detail secrets | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["ok"] and "unrecognized" in d["error"], d' || fail "secret row accepted: $bad"
done
FAKE_SECRETS='no secrets\n' "$HELPER" detail secrets | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and d["data"]==[]'
"$HELPER" action net-allow rku7 '*.example.com'
"$HELPER" action net-join my-net rku7
"$HELPER" action secret-rm EXAMPLE_KEY
"$HELPER" action new-named s my-box
"$HELPER" action resize rku7 m
"$HELPER" action port-private nvbg 3000
for call in 'net allow rku7 *.example.com' 'net join my-net rku7' 'secret rm EXAMPLE_KEY' 'new -s s --name my-box' 'resize rku7 m' 'port nvbg 3000 --private'; do
  grep -Fxq "$call" "$LOG" || fail "$call missing"
done
for kind in old free malformed; do
  FAKE_DETAILS="$kind" "$HELPER" detail networks |
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["ok"] and sys.argv[1] in d["error"],d'       "$(case $kind in old) echo 'Update CLI';; free) echo 'Orble Pro';; malformed) echo 'unrecognized';; esac)"
done
before=$(wc -l < "$LOG")
"$HELPER" detail secrets --demo | python3 -c 'import json,sys; assert json.load(sys.stdin)["ok"]'
if "$HELPER" action net-allow rku7 --help; then fail "invalid egress entry"; fi
if "$HELPER" action net-allow rku7 999.999.999.999; then fail "invalid IPv4 entry"; fi
if "$HELPER" action secret-set EXAMPLE_KEY example.com; then fail "secret set must use terminal path"; fi
[[ $(wc -l < "$LOG") == "$before" ]] || fail "invalid action reached CLI"
ok

# --- projects: listed in status, --project reaches every call, a missing one is reported ---
: > "$LOG"
out=$("$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["projects"]==[{"slug":"default","name":"Default"},{"slug":"client-work","name":"Client work"}] and d["project"]=="" and not d["projectMissing"], d' "$out" || fail "projects in status"
out=$(FAKE_OLD_CLI=1 "$HELPER" status)
python3 -I -c 'import json,sys; assert json.loads(sys.argv[1])["projects"]==[]' "$out" || fail "old CLI has no projects"
out=$(ORBLE_PROJECT=client-work "$HELPER" status)
python3 -I -c 'import json,sys; assert json.loads(sys.argv[1])["project"]=="client-work"' "$out" || fail "ORBLE_PROJECT not reported"
: > "$LOG"
out=$("$HELPER" --project client-work status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["project"]=="client-work"' "$out" || fail "--project status"
for call in 'ls --json' 'snapshots --json' 'account' 'keys' 'project list' '--help'; do
  grep -Fxq -- "--project client-work $call" "$LOG" || { cat "$LOG"; fail "--project missing on: $call"; }
done
"$HELPER" --project client-work ports rku7 > /dev/null
"$HELPER" --project client-work detail secrets > /dev/null
"$HELPER" --project client-work action suspend rku7
"$HELPER" --project client-work exit-node --lan rku7 > /dev/null
for call in 'port rku7' 'secret ls' 'suspend rku7' 'exit-node --lan rku7'; do
  grep -Fxq -- "--project client-work $call" "$LOG" || { cat "$LOG"; fail "--project missing on: $call"; }
done
out=$("$HELPER" --project nope status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert not d["ok"] and d["projectMissing"] and d["project"]=="nope" and len(d["projects"])==2, d' "$out" || fail "missing project"
before=$(wc -l < "$LOG")
for bad in 'Client' '-rf' '' 'a/b'; do
  if "$HELPER" --project "$bad" status 2>/dev/null; then fail "bad project slug accepted: $bad"; fi
done
[[ $(wc -l < "$LOG") == "$before" ]] || fail "bad project slug reached CLI"
# A project is made for the account, so project create never carries --project.
: > "$LOG"; : > "$NOTES"
"$HELPER" --project client-work action project-create 'Client work 2'
[[ $(cat "$LOG") == 'project create Client work 2' ]] || { cat "$LOG"; fail "project create argv"; }
grep -q "Project Client work 2 created" "$NOTES" || { cat "$NOTES"; fail "project create note"; }
refuse action project-create '-x'
refuse action project-create 'a$(id)'
refuse action project-create "$(printf 'x%.0s' {1..41})"
ok

# --- secret-set: comma-separated hosts, Orble's default header and format, the project (needs a tty) ---
if command -v script > /dev/null; then
  : > "$LOG"
  script -qec "'$HELPER' --project client-work secret-set NEW_KEY api.example.com,example.com '' '' scoped rku7 base1" /dev/null < /dev/null > /dev/null
  script -qec "'$HELPER' secret-set NEW_KEY api.example.com X-Api-Key 'Key {}' all-intercept" /dev/null < /dev/null > /dev/null
  [[ $(cat "$LOG") == $'--project client-work secret set NEW_KEY --host api.example.com --host example.com --box rku7 --box base1\nsecret set NEW_KEY --host api.example.com --header X-Api-Key --format Key {} --intercept' ]] || { cat "$LOG"; fail "secret-set argv"; }
  : > "$LOG"
  for args in "NEW_KEY a.com,a.com '' '' all" "NEW_KEY a.com,-x '' '' all" "NEW_KEY a.com 'X Y' '' all" "NEW_KEY a.com '' 'no braces' all" "NEW_KEY a.com '' '' scoped" "new_key a.com '' '' all"; do
    script -qec "'$HELPER' secret-set $args" /dev/null < /dev/null > /dev/null || true
  done
  [[ ! -s $LOG ]] || { cat "$LOG"; fail "invalid secret-set reached the CLI"; }
  ok
else
  echo "helper-test: script(1) missing, skipping the secret-set terminal test" >&2
fi

echo "helper-test: $pass groups passed"
