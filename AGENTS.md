# AGENTS.md: Orble Helper

Guide for coding agents (and people) changing this plugin. Read [README.md](README.md) first. It is the Orble sibling of `thelaggingway.instabox-helper` and follows the same layout and rules.

## Layout

| Path | Role |
|---|---|
| `manifest.json` | Omarchy manifest: id `thelaggingway.orble-helper`, `bar-widget`, settings schema. |
| `Panel.qml` | Bar icon + `KeyboardPanel`: state, polling, action dispatch, confirm dialog, terminal launches, the exit-node `Process`. Inline components: `PlainText`, `StateDot`, `ActionButton`, `Chips`, `CreditCard`, `ExitNodeCard`, `BoxRow`, `KeyRow`, `LocalKeyRow`. |
| `Model.js` | `.pragma library` pure helpers, run under Node in tests. |
| `bin/orble-panel` | Python 3 stdlib, `python3 -I`. `status`, `action <verb>`, `exit-node`, and the terminal commands `ssh`, `desktop`, `topup`, `login`. The only code that runs `orble`. |
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

To check the expanded box or the keys list, temporarily set the `expandedBox` / `keysOpen` defaults in `Panel.qml`, restart the shell, screenshot (`grim -o <output>`), and put them back.

**Don't run actions against a real account** unless the user asks; `status` is the only read-only command. `helper-test.sh` covers the argv of every action against a fake CLI.

## Invariants (tests enforce most)

1. **Plain text only**: `PlainText`, never a bare `Text {}`.
2. **Argv only**: arrays in QML, `subprocess` lists in Python, never `sh -c` or `shell=True`.
3. **Validate before the CLI runs**: `NAME_RE` (same in Python and `Model.js`), `FP_RE`, `KEYFILE_RE` + realpath inside `~/.ssh`, `check_dollars` 10–500. The CLI doesn't validate (`orble rm --help` asks to delete a box named `--help`).
4. **Whitelisted verbs**: `ONE_ARG` or an explicit branch in `action()`. Unknown verbs exit before calling the CLI.
5. **Never start a sign-in in the background.** `signed_in()` checks only that `config.json` has a `token` (never reads it out; `source-test.sh` checks the word appears once). `cli()` kills the CLI as soon as it prints a sign-in marker.
6. **Never reach a prompt in the background.** stdin is `/dev/null`; `rm` gets `-y`; `keys add` gets a path; `new` is refused when `account` shows credit ≤ 0 (the CLI would offer a top-up).
7. **Money is visible and confirmed.** `topup` is in `confirmVerbs` and runs only via `openTerminal`, never as a background action.
8. **The exit node stops like Ctrl-C**: `exitProc.signal(2)`, with a 10 s fallback. The helper `execve`s the CLI so the signal reaches it directly.
9. **QML list wrappers**: status arrays stored in a `property var` fail `Array.isArray`; read them by index (`flagsOf`) or with `filter`/`map`.
10. **Demo mode** guards `runAction` and `openTerminal`; the exit node runs the helper's fake `exit-node --demo`.
11. No caches, state files or secrets.

## CLI facts this depends on

Checked against the `orble` CLI of 2026-11-14 (`orble update` reported `515f19f2`). No `--json` anywhere; confirm table layouts after CLI updates.

- `ls`: `NAME  STATE  HOST  SIZE  SPENT  ACTIVE` then unlabeled extra words (`desktop` while the desktop runs). STATE is a glyph + word (`◐ suspended`, `● running`). SIZE `2c/4g`. Columns are aligned by rune. No boxes: `No boxes yet. Create one: orble new`.
- `account`: email line, then `  boxes   <box>.<slug>.orble.tech`, `  credit  $5.00`, `  keys    1`.
- `keys`: `<name>  SHA256:<43 chars>` per line. `keys add [file]` prompts for a path without one. `keys rm <fingerprint>`.
- Box hosts resolve to IPv6 only: plain `ssh <host>` fails on IPv4-only networks ("Network is unreachable"), while `orble ssh <box> [-- cmd]` routes the connection itself. Copy SSH therefore copies `orble ssh <box>`.
- `new [--ssh]` prints `✓ <name> ready in 0.16s`. No name, size or template options.
- `suspend|resume|vnc <box>`, `rm <box> [-y]`, `desktop <box> [--off]` (viewer: `xtigervncviewer` or `remmina`, tunnel on 127.0.0.1:5901).
- `exit-node [--lan] [--fallback] [box...]` runs until Ctrl-C.
- `topup [dollars]` (10–500), `login` (Google, device code), `update`, hidden `__boxes`, `completion bash|zsh|fish`.
- Idle boxes suspend on their own ("Automatic suspend" on orble.tech) and SSH resumes them; the idle timeout is undocumented and the CLI has no setting for it.
- Config: `$XDG_CONFIG_HOME/orble/config.json` with `api`, `token`, `domain`.

## Releasing

Bump `version`, run `tests/run.sh`, commit, push. If listed on the Omarchy marketplace, each release needs a Plugin verification issue (see the Instabox Helper notes). Keep the repo free of `install*`/`setup*` files, privilege escalation, service-manager and package-manager calls.
