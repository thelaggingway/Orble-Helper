# Orble Helper

An [Omarchy](https://omarchy.org/) bar plugin for [Orble](https://orble.tech), sandboxes for AI agents. It puts your boxes, credit, SSH keys and the exit node in a panel on the bar, covering everything the `orble` CLI does: new boxes, one-click SSH, suspend and resume, the desktop in your browser or a VNC viewer, the exit node with its LAN and fallback options, SSH keys, top-ups, sign-in and CLI updates.

It is a front end to the official `orble` CLI and uses the CLI's own sign-in. The plugin stores no token or password.

![The Orble Helper panel, showing made-up demo data](preview.png)

*The panel with **Demo data** on (made-up boxes, keys and credit), one box expanded and the exit node running.*

## What it does

**Bar icon.** A server icon that lights up while any box is running, with the count beside it, and a globe while the exit node is on. It is highlighted when you're signed out or your credit is low. Left-click opens the panel and right-click refreshes.

**Credit.** Your credit, account and box hostname pattern (`<box>.<account>.orble.tech`). **Add credit** offers $10, $25, $50 or $100; after you confirm, `orble topup <amount>` runs in a terminal, where you finish paying the way the CLI asks. The plugin never pays anything itself.

**New box (+).** Runs `orble new`. The notification names the box and how fast it started. With no credit, the panel refuses rather than letting `orble new` prompt for a top-up in the background.

**Boxes.** Every box shows its state, size and spend, with two buttons:

| Button | What happens |
|---|---|
| Terminal (SSH) | Opens a terminal with `orble ssh <box>`; a suspended box resumes on connect. |
| Play / pause | `orble suspend` a running box (processes are kept) or `orble resume` it. |

Click a box for its hostname, when it was last active, whether its desktop is on, and:

| Action | CLI | Asks first? |
|---|---|---|
| Copy SSH | copies `orble ssh <box>` (boxes are IPv6-only, so a plain `ssh <host>` fails on IPv4-only networks) | No |
| Desktop | `orble vnc <box>`: the desktop in your browser, started if needed | No |
| VNC viewer | `orble desktop <box>` in a terminal (shown only when `xtigervncviewer` or `remmina` is installed) | No |
| Desktop off | `orble desktop <box> --off` (shown while the desktop runs) | No |
| Delete | `orble rm <box> -y` | Yes |

**Exit node.** Sends boxes' traffic through this machine, from its IP, while it runs (`orble exit-node`). Pick boxes (none picked means the ones switched on in the Orble dashboard), and optionally **LAN** (`--lan`: boxes reach your LAN, VPN or tailnet) and **Fallback** (`--fallback`: boxes use Orble's network while this machine is offline). **Stop** sends Ctrl-C (SIGINT) so the CLI puts the boxes back on Orble's network. The exit node runs as long as the shell does; restarting the shell or logging out stops it.

**SSH keys.** The keys on your account, each removable (`orble keys rm <fingerprint>`, asks first), and the `.pub` files in `~/.ssh` that aren't on the account yet, each with **+** to add it (`orble keys add <file>`).

**Footer.** When the list was refreshed, **Update CLI** (`orble update`) and **Dashboard**.

Every background action sends a notification when it finishes, saying whether it worked and, if not, what the CLI said.

## Requirements

- Omarchy with the Quickshell-based shell.
- The [`orble` CLI](https://orble.tech/docs), signed in (`orble account`).
- `python3`, `ssh-keygen`, `wl-copy` and `xdg-open`, which Omarchy ships. Optional: `tigervnc` or `remmina` for the VNC viewer button.

## Install

```bash
omarchy plugin add https://github.com/thelaggingway/Orble-Helper.git --enable
omarchy restart shell
```

If you're signed out, the panel shows **Sign in to Orble**, which runs `orble login` in a terminal.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `120` | How often to check while the panel is closed; every 10 s while it is open or an action runs. |
| `showCount` | `true` | Show the number of running boxes next to the icon. |
| `showCredit` | `true` | Show the credit card. |
| `lowCreditUSD` | `1` | Below this the credit turns red and the icon is highlighted; `0` turns it off. |
| `demoMode` | `false` | Made-up boxes, keys and credit for screenshots. The CLI is never called and actions do nothing. |

```bash
omarchy bar set thelaggingway.orble-helper refreshIntervalSec 300
omarchy bar set thelaggingway.orble-helper demoMode true --json
```

## Keyboard and scripting

```bash
omarchy-shell thelaggingway.orble-helper toggle     # also open, close, refresh
omarchy-shell thelaggingway.orble-helper newBox     # orble new
omarchy-shell thelaggingway.orble-helper exitNode   # start or stop the exit node
```

The helper works on its own too:

```bash
H=~/.config/omarchy/plugins/thelaggingway.orble-helper/bin/orble-panel
$H status | jq .
$H action suspend <box>
$H exit-node --lan <box>
```

## How it works

```
Panel.qml ──argv──▶ bin/orble-panel ──argv──▶ orble CLI ──HTTPS──▶ orble.tech
```

- **`bin/orble-panel`** (Python, standard library) is the only code that runs `orble`. The CLI has no JSON output, so `status` runs `ls`, `account` and `keys` in parallel and parses their tables by the header's column positions.
- **`Panel.qml`** draws everything, polls `status`, runs actions as child processes, opens terminals for SSH, the VNC viewer, top-ups and sign-in, and owns the exit-node process.
- **`Model.js`** holds the pure formatting logic, tested under Node.

### Security and privacy

- **No secrets.** Signed out, every `orble` command starts a browser sign-in, so the background poll must not run one. The helper checks only *whether* `~/.config/orble/config.json` has a token, never reading it out, and reports "Not signed in" without calling the CLI. If the CLI starts a sign-in anyway (an expired token), the call is ended at once.
- **No shell strings, strict input.** Every process gets a fixed argument list. Box names must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`, fingerprints `SHA256:` plus 43 base64 characters, key files must be `.pub` files directly in `~/.ssh` (links resolved), and top-ups whole dollars from 10 to 500. Nothing can become a flag (the CLI itself would happily try to delete a box named `--help`).
- **No prompts in the background.** The CLI gets empty stdin, `rm` always gets `-y`, `keys add` always gets a file, and `new` is refused at zero credit.
- **Asks first:** delete, key removal and top-ups. Top-ups only ever run in a visible terminal.
- **Plain text only**, for names and CLI output.
- **Network use:** only what the `orble` CLI does: 3 requests every 2 minutes in the background, every 10 s while the panel is open, plus the actions you click. No cache or state files.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No icon after installing | `omarchy restart shell`, or `omarchy bar put thelaggingway.orble-helper`. |
| "Not signed in" | **Sign in to Orble**, or `orble login`. |
| "Can't reach Orble" | The error is the CLI's; try `orble ls`. |
| A box shows odd fields | The CLI's table layout changed. Compare `orble ls` with `bin/orble-panel status`. |
| No VNC viewer button | Install `tigervnc` or `remmina`, or use **Desktop** (browser). |
| Shell log | `journalctl --user -f -o cat \| grep -i orble` |

## Update and uninstall

```bash
omarchy plugin update thelaggingway.orble-helper && omarchy restart shell
omarchy plugin remove thelaggingway.orble-helper
```

Removing the plugin stops the exit node if it is running (it lives in the shell). The `orble` CLI, its sign-in and your boxes are untouched; remove those with the CLI (`orble rm <box>`) or the Orble dashboard.

## Development

```bash
tests/run.sh    # static checks, the helper against a fake orble CLI, Model.js under Node
```

See [AGENTS.md](AGENTS.md). MIT licensed; Orble is a separate service and this plugin is not affiliated with it.
