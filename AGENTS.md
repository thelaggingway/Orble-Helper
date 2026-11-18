# AGENTS.md: Orble Helper

Guide for coding agents (and people) changing this plugin. Read [README.md](README.md) first. It is the Orble sibling of `thelaggingway.instabox-helper` and follows the same layout and rules.

## Layout

| Path | Role |
|---|---|
| `manifest.json` | Omarchy manifest: id `thelaggingway.orble-helper`, `bar-widget`, settings schema. |
| `Panel.qml` | Bar icon + `KeyboardPanel`: state, polling, action dispatch, confirm dialog, terminal launches, the exit-node `Process`. Inline components: `KeyField`, `PlainText`, `StateDot`, `ActionButton`, `Chips`, `CreditCard`, `ExitNodeCard`, `BoxRow`, `PortRow`, `SnapshotRow`, `KeyRow`, `LocalKeyRow`. Text entry (snapshot name, port) is `KeyField`, which sets `editorFocus`, which blocks the `PanelKeyCatcher` while they have focus. |
| `Model.js` | `.pragma library` pure helpers, run under Node in tests. |
| `bin/orble-panel` | Python 3 stdlib, `python3 -I`. `status`, `ports <box>`, `action <verb>`, `exit-node`, `keep-awake`, and the terminal commands `ssh`, `desktop`, `topup`, `login`. The only code that runs `orble`. |
| `tests/` | `run.sh` → `source-test.sh` (static rules), `helper-test.sh` (fake `orble` on PATH, fake `~/.ssh` and config), `model-test.mjs`. `marketplace-scan.mjs` runs the Omarchy marketplace's security baseline (CI clones the marketplace). |

## Run, reload, test

```bash
tests/run.sh
omarchy restart shell
omarchy-shell thelaggingway.orble-helper toggle
journalctl --user -f -o cat | grep -i orble
bin/orble-panel status | jq .      # read-only, safe against the real account
omarchy plugin validate .
```

To check the expanded box, temporarily set the `expandedBox` default in `Panel.qml`, restart the shell, screenshot (`grim -o <output>`), and put them back.

**Don't run actions against a real account** unless the user asks; `status` is the only read-only command. `helper-test.sh` covers the argv of every action against a fake CLI.

## Invariants (tests enforce most)

1. **Plain text only**: `PlainText`, never a bare `Text {}`.
2. **Argv only**: arrays in QML, `subprocess` lists in Python, never `sh -c` or `shell=True`.
3. **Validate before the CLI runs**: `NAME_RE` (same in Python and `Model.js`; snapshot names too), `check_port` 1–65535, `FP_RE`, `KEYFILE_RE` + realpath inside `~/.ssh`, `check_dollars` 10–500. The CLI doesn't validate (`orble rm --help` asks to delete a box named `--help`).
4. **Whitelisted verbs**: `ONE_ARG` or an explicit branch in `action()` (`new [s|m|l]`, `new-from <snapshot> [s|m|l]`, `fork <box> [1-10]`, `snapshot <box> [name]`, `snapshot-rm <snapshot>`, `port|port-public|port-off <box> <port>`, `keys-*`, `update`). Unknown verbs exit before calling the CLI.
5. **Never start a sign-in in the background.** `signed_in()` checks only that `config.json` has a `token` (never reads it out; `source-test.sh` checks the word appears once). `cli()` kills the CLI as soon as it prints a sign-in marker.
6. **Never reach a prompt in the background.** stdin is `/dev/null`; `rm` and `snapshot rm` get `-y`; `keys add` gets a path; `new`, `new-from` and `fork` are refused when `account` shows credit ≤ 0 (the CLI would offer a top-up).
7. **Money and exposure are visible and confirmed.** `fork` (a new billed box), `snapshot-rm`, `port-public` (open to anyone) and `topup` are in `confirmVerbs`; `topup` and runs only via `openTerminal`, never as a background action.
8. **The exit node stops like Ctrl-C**: `exitProc.signal(2)`, with a 10 s fallback. The helper `execve`s the CLI so the signal reaches it directly.
9. **QML list wrappers**: status arrays stored in a `property var` fail `Array.isArray`; read them by index (`flagsOf`) or with `filter`/`map`.
10. **Keep awake** is one long-running `keep-awake <box>...` helper owned by `awakeProc`; changing the list restarts it (SIGTERM, then `onExited` starts the new list). It never loops on its own failures, stops at a sign-in prompt (exit 3), and suspending a box from the panel drops that box first, or the reconnect would resume it.
11. **Demo mode** guards `runAction` and `openTerminal`; the exit node runs the helper's fake `exit-node --demo`.
12. No caches, state files or secrets.
13. **No native text inputs** (`TextField`, `TextInput`, `TextEdit`, `TextArea`): a writable one fetches the clipboard on every clipboard change with no size limit (marketplace review on #14930). Use `KeyField`, which takes typed keys only (filtered by its `allowed` regex) and has no paste. `source-test.sh` enforces this.

## Current CLI additions

Verified against `bc07c8bf`. `ls --json` uses `name` as the stable identity and `alias` as the display name. `snapshots --json` keeps the original `name` after renaming, adds `alias`, and marks built-in entries with `gallery: true`. A private shared port may be labeled `private` or `signin`, depending on the build.

`detail egress <box>`, `detail networks`, and `detail secrets` return validated, on-demand JSON projections of the CLI's text output. Network actions use the stable box name, and the panel offers aliases for picking boxes. The separate `secret-set` command requires a terminal and accepts metadata only. The CLI handles the hidden prompt. Keep secret values and generated placeholders out of plugin status, logs, and notifications.

## CLI facts this depends on

Checked against the `orble` CLI of 2026-11-16 (`a456dba3`, which added `snapshot`, `snapshots` and `port`; first written against `515f19f2`). `ls --json` and `snapshots --json` exist; `account`, `keys` and `port` have no JSON, so confirm their layouts after CLI updates. The full command list is orble.tech/docs?tab=cli (also orble.tech/docs.md).

- `ls --json` (what `status` uses): a list of `{name, hostname, state, desktop, vcpus, mem_mib, disk_gib, ipv6, host_key, spent_micros, created_at, last_active_at}`. The helper passes on only what the panel shows (never `ipv6`/`host_key`), derives the size class from vCPU/memory, and `ACTIVE`-style text from `last_active_at`. A fork's parent field is `forked_from` (the JSON tag in the `a456dba3` binary; not yet seen live); `fork_parent()` also accepts `forkedFrom`, `parent`, `fork_of` (string or `{name}`), and `fork_order()` puts forks after their parent with a `depth` the panel indents by. If `ls --json` doesn't give a list, the helper falls back to the table below.
- `ls` (table fallback): `NAME  STATE  HOST  SIZE  SPENT  ACTIVE` then unlabeled extra words (`desktop` while the desktop runs). STATE is a glyph + word (`◐ suspended`, `● running`). SIZE `s 2c/4g` (size class s|m|l, then vCPUs/GiB; before `adcd323c` just `2c/4g`, still parsed). Columns are aligned by rune. No boxes: `No boxes yet. Create one: orble new`.
- `account`: email line, then `  boxes   <box>.<slug>.orble.tech`, `  credit  $5.00`, `  keys    1`.
- `keys`: `<name>  SHA256:<43 chars>` per line. `keys add [file]` prompts for a path without one. `keys rm <fingerprint>`.
- Box hosts resolve to IPv6 only: plain `ssh <host>` fails on IPv4-only networks ("Network is unreachable"), while `orble ssh <box> [-- cmd]` routes the connection itself. Copy SSH therefore copies `orble ssh <box>`.
- `new [-s s|m|l] [--ssh]` prints `✓ <name> ready in 0.16s`. Sizes: s 2 vCPU 4 GiB (default), m 4/8, l 8/16. No name or template options.
- `fork <box> [-n N]` (1–10): new boxes carrying on from this one. Output not yet seen live; the helper collects every `<name> ready` it prints. Per the docs, a fork carries running programs over too. Like `new`, it may offer a top-up at zero credit, so it gets the same credit check.
- Snapshots (live-tested 2026-11-16 on `nvbg`, then deleted): `snapshot <box> [name]` prints `✓ saved nvbg as plugin-test m 4c/8g, 409 MB, in 1.13s` then `  orble new --from plugin-test`; with no name the CLI picks one. `snapshots --json`: a list of `{name, box, state ("ready"), vcpus, mem_mib, disk_bytes, created_at}`; the table is `NAME  FROM BOX  SIZE  DISK  CREATED`, empty: `No snapshots yet. Save one: orble snapshot <box>`. `snapshot rm <name>` asks `[y/N]`; on empty stdin it prints `Kept it.` and exits **0**, so the helper always passes `-y` (prints `✓ deleted snapshot <name>`). `new --from <snapshot> [-s size]`: at the snapshot's size the box has its files and running programs, larger only its files; it keeps the snapshot's desktop setting. Not tried live (it bills a new box); the helper reads `<name> ready` like `new`. A CLI from before `a456dba3` prints its help for `snapshots --json`, which `status` reports as `snapshotsSupported: false` and the panel hides the section. `new`/`fork`/`snapshot` also take `--json` (not used).
- Ports (live-tested 2026-11-16 on `nvbg`): `port <box>` lists `8080   signin  https://8080-yj3vcxk7lezdtgpc.orble.dev` (port, access `signin` or presumably `public`, URL), or `no shared ports`; it doesn't resume a suspended box. `port <box> <port>` prints `✓ nvbg:8080 signin` then the URL; `--off` prints `✓ nvbg:8080 unshared` (an unshared port: `orble: port 8081 isn't shared`, exit 1). `--public` was refused on this account: `orble: public ports are for accounts that have added credit` (exit 1), so the public listing word is unconfirmed.
- `suspend|resume|vnc <box>`, `rm <box> [-y]`, `desktop <box> [--off]` (viewer: `xtigervncviewer` or `remmina`, tunnel on 127.0.0.1:5901).
- `exit-node [--lan] [--fallback] [box...]` runs until Ctrl-C.
- `topup [dollars]` (10–500), `login` (Google or GitHub, device code), `update`, hidden `__boxes`, `completion bash|zsh|fish`, `whoami`.
- Auto-suspend (measured 2026-11-14): a box suspends about 1 minute after its last SSH connection closes. An open SSH session or an open desktop viewer keeps it awake; running processes do not (a tmux job froze while suspended and carried on after resume, so processes survive but nothing runs). `ls` ACTIVE is the time since the last connection started. Boxes can be pinned awake in the dashboard only; the CLI has no pin.
- Prices (orble.tech/pricing, 2026-11-16): S $0.015/h, M $0.03/h, L $0.06/h while running, all 64 GiB disk; suspended $0; storage $0.05/GiB-month. They live in `Model.sizeOptions`; update them if the pricing page changes.
- Orble also runs an MCP server (`https://orble.tech/mcp`); the plugin doesn't use it.
- Config: `$XDG_CONFIG_HOME/orble/config.json` with `api`, `token`, `domain`.

## Releasing

Bump `version`, run `tests/run.sh`, commit, push. If listed on the Omarchy marketplace, each release needs a Plugin verification issue (see the Instabox Helper notes). Keep the repo free of `install*`/`setup*` files, privilege escalation, service-manager and package-manager calls.
