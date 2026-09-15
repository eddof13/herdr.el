# herdr.el

Drive [herdr](https://herdr.dev) — a terminal workspace manager for AI coding agents — from
Emacs, with herdr's terminals hosted **inside** Emacs via
[ghostel](https://github.com/dakra/ghostel).

There is no second terminal application in the loop. Commands go over herdr's unix socket, a live
event stream keeps a cache of the session, and that cache feeds a
[transient](https://github.com/magit/transient) menu, a modeline segment, an agent status buffer,
and completion pickers.

```
M-x herdr   [w1:p1  claude:idle]   C-u on any command retargets

 Go to            Menus             Session
  p pane           P pane…           g resync
  a agent          A agent…          l agents
  w workspace      W workspace…      s status
  t tab *          T tab… *          : any method…
                   % worktree…

  * session backend only
```

**Tabs are hidden entirely under `agent-windows`.** A tab is a grouping inside a workspace whose
only visual form is the TUI's tab bar, so where nothing renders a tab, nothing tab-shaped is
offered — `herdr-call` still reaches the methods if you want them.
Workspaces are *not* hidden: they are keyed by cwd, persist across restarts, group the agents
buffer, and back `herdr-project`. Going to one shows that workspace's active pane — one buffer,
in the current window, not all of them.

**Targeting.** Commands act on the pane of the buffer you are in, if that is a herdr terminal;
otherwise on the pane herdr has focused. `C-u` on any command prompts instead. The header names
the pane that will be acted on, so it is never a guess.

**Key scheme.** A lowercase noun jumps to that kind of thing; the same letter uppercased opens
its menu. Inside a menu, verbs are constant: `c` create, `f` focus, `r` read, `R` rename, `k`
close/remove, `l` list. `?` and `C-h` are left to transient's own help, so status is `s`.
Worktrees are on `%` and the raw-method escape hatch on `:`, matching where magit puts those two
ideas. Asserted by tests, not just by review.

## Requirements

- Emacs 28.1+
- [herdr](https://herdr.dev) 0.9.0 (protocol 22)
- `ghostel`, `transient`

Optional, used when present, never required: `marginalia`, `embark`, `consult`, `alert`.

## Install

```elisp
(use-package herdr
  :ensure nil                          ; local checkout, not on MELPA
  :load-path "~/src/herdr.el"
  :bind (("C-x M" . herdr)             ; pairs with C-x m if you bind ghostel there
         ("C-c H" . herdr-agents)
         :map project-prefix-map
         ("h" . herdr-project))
  :custom (herdr-terminal-backend 'session)
  ;; (herdr-display-action '(display-buffer-full-frame))  ; TUI takes the frame
  :config (herdr-agents-mode-line-mode 1))
```

`:ensure nil` matters if you set `use-package-always-ensure` — without it Emacs tries MELPA and fails at startup.

`M-x herdr` starts the server if it is not running, brings up the terminals, connects the event
stream, and opens the menu.

## Terminal backends

Both are supported. Set `herdr-terminal-backend`.

### `session` (default)

One ghostel buffer, `*herdr*`, running the herdr TUI. herdr owns the layout. Plain shell panes
work normally. About sixty lines of glue and nothing to go wrong.

`herdr-display-action` controls placement, and every path that shows a herdr buffer goes through
it — starting herdr, going to a pane, attaching — so the same buffer cannot appear one way from
`M-x herdr` and another from Go to.

It defaults to reusing the current window and leaving your splits alone. herdr's TUI wants width
for its 26-column sidebar, so under `session` you may prefer
`'(display-buffer-full-frame)` — which does delete your other windows — or a side window.

The TUI is mouse-first — click panes, drag borders, right-click menus. ghostel forwards those
clicks, but only under **GUI Emacs**: a TTY frame (`emacs -nw`) has no mouse events to forward, so
there drive the TUI by keyboard (its `ctrl+b` prefix) or use `agent-windows`, which is
keyboard-first and needs no TUI at all.

### `agent-windows`

One ghostel buffer per agent — `*herdr: claude w1:p1*` — each running `herdr agent attach`.
Emacs owns the layout; herdr's own layout tree goes unused, so there is no geometry to keep in
sync.

**Attaching is lazy, and nothing splits.** `M-x herdr` takes no windows and opens no buffers; a
pane is attached the first time you go to it, in the current window. Splitting stays yours —
`C-x 2`, `C-x 3`, `display-buffer-alist`.

Laziness is not only politeness: the attach client needs a window when it starts, so attaching
every agent up front would mean taking a window per agent before you had asked for anything. Once
started it survives being buried, so you can switch away freely.

The reason to want it: **agents survive Emacs exiting**, because the herdr server is a daemon.
Quit Emacs, restart, `M-x herdr`, and every agent is still there and reattached. A plain ghostel
shell cannot do that — it is a child of Emacs and dies with it.

The cost: `herdr agent attach` refuses a pane with no detected agent, so plain shell panes get no
buffer by default. They stay reachable through `pane.read`, `pane.send_text`,
`pane.wait_for_output` and the menu, and `ghostel-project` covers ordinary interactive shells.

### Adopting a shell

"Pane" here always means a **herdr pane** — a PTY and shell process owned by the herdr daemon,
with an id like `w2:p1`. It is not a ghostel buffer and not an Emacs window. The daemon forks the
shell; Emacs only ever asks it to. That is why a pane outlives Emacs, and why adoption happens
*before* any buffer exists — a ghostel buffer is what you get after adopting, not the thing being
adopted.

herdr panes you create *from Emacs* — split, new tab, new workspace — are adopted automatically,
so they get buffers like anything else. That is `herdr-adopt-created-shells`, on by default. The
rule is about provenance: panes appearing from anywhere else, including ones an agent creates for
itself, are never claimed behind your back.

Provenance is judged once, when the command runs; there is no lasting record that Emacs created a
pane. The adoption it produces *is* lasting, though, because the reported agent is server-side
state — so an adopted pane is still adopted after you restart Emacs.

`M-x herdr-adopt-shell` does the same for any pane you point it at, by reporting an agent named
`herdr-shell-agent-name` (default `shell`) — which is the only thing `agent attach` checks. Use it
for a pane you want to watch in Emacs *and* keep running across an Emacs restart, such as a long
build.

Adopted shells get buffers but are **not** treated as agents: they stay out of the modeline count,
the agent picker and notifications, since a shell has no lifecycle. They show as `shell*` with a
`~` glyph in `*herdr-agents*`.

**Adoption suppresses herdr's own agent detection for that pane.** Reporting an agent takes
lifecycle authority, so the reported label outranks the detector: start Claude inside an adopted
shell and the pane stays labelled `shell`. herdr.el compensates by reading what the detector
concluded — `agent.explain` still reports it — and relabelling the pane accordingly. That runs on
the poll; `M-x herdr-promote-shell` (`P G`) does it now.

Do not try to fix this with `pane.release_agent` or `pane.clear_agent_authority`. Detection binds
when an agent starts and does not re-run, so releasing leaves the pane with *no* agent rather than
the one plainly running in it, and the only way back is restarting the agent.

The visible cost is one row in herdr's own sidebar, in its agents section, labelled `shell`. That
section's membership rule is simply "has a reported agent", and herdr's sidebar does not list
non-agent panes at all — so there is no "plain shell" row for it to be instead.
`M-x herdr-release-shell` reverses it completely.

## What was measured

The design rests on behaviour probed from a live herdr rather than from documentation.
Recorded here because most of it is not written down anywhere else.

| Behaviour | Finding |
|---|---|
| RPC connections | **One request per connection.** The server writes one response, then closes. No multiplexing, no id correlation. |
| `events.subscribe` | The one long-lived call. Acks `subscription_started`, then streams. |
| **Subscribe does not replay** | Lifecycle subscriptions start live. Clients subscribe first, wait for the ack, buffer, take `session.snapshot`, install it, then apply the buffer. Snapshot-then-subscribe misses the gap. |
| **`pane_updated` coalesces** | Driving a pane through working → blocked → idle produced **3** per-pane events but only **1** `pane_updated`. Global events alone silently lose status transitions, so per-pane `pane.agent_status_changed` subscriptions are required. |
| Throughput | Not a concern for either backend. A **12.2 MB** pane dump reached Emacs as **17 KB** (`session`) / **24 KB** (`agent-windows`), completing in 0.2s. herdr's VT only emits visible-frame diffs. |
| `agent attach` | Streams one pane full-screen; coexists with a session client; **exclusive per pane**; refuses panes without a detected agent. |
| Attach needs a window | The client needs a window when it starts and dies if that window is *deleted*; being merely hidden is fine, so a buried terminal keeps running with its scrollback. A zero-sized PTY renders nothing. |
| **Cache can still drift** | A disconnect gap, or a `cd` that never emits `pane_updated`, leaves the cache wrong. The pane set is reconciled against `pane.list` on a poll. |
| **Adoption outranks detection** | `pane.report_agent` takes lifecycle authority, so an adopted pane keeps its label even once a real agent starts in it. `agent.explain` still reports what the detector concluded, which is what promotion reads. Releasing authority does *not* restore detection — it binds at agent start and does not re-run. |
| Focus | `pane.focus` sets the session's focused pane. Viewing clients can present different workspaces and tabs independently; `pane.focused` reports a selection without moving other clients' views. |
| OSC | **Not** forwarded — herdr's VT consumes OSC 7 and OSC 133. Beware the false positive: sending the escapes inline makes the shell echo the command text, which contains the same characters. |
| cwd tracking | herdr tracks it **itself** — `pane.cwd` follows a `cd` within about a second. But it publishes **no event** for it: a `cd` emits only `layout_updated` noise, so directory tracking has to poll (debounced off the event stream, with a slow backstop timer). |
| Shell panes | `pane.report_agent` makes a plain shell pane attachable, which is how adoption works. |
| `pane.read` shape | Text is nested under a `read` object, not a top-level field. Recent reads include output still in the viewport. |
| `workspace.close` | Closing a primary workspace that still has linked worktree workspaces requires `close_group: true`, otherwise the group stays open (`workspace_group_close_required`). |
| `WorkspaceInfo` | Has no cwd. A worktree workspace is identified by `worktree.checkout_path`; any other workspace is identified by its panes' cwd. |
| JSON arrays | Emacs's `json-serialize` cannot distinguish a list of alists from one alist. Array parameters must be vectors or `events.subscribe` is rejected. |

## Commands

34 curated commands cover the methods worth a keybinding; `M-x herdr-call` reaches all
**103**, prompting for each parameter from the server's own schema. Nothing is out of reach and
there is no generated 103-entry menu.

Worth knowing about:

- **`herdr-agent-start`** — starts an agent in an idle pane. The picker also offers a trailing
  **＋ new shell pane** entry that splits the current pane and starts there, so a session with no
  free pane is never a dead end.
- **`herdr-worktree-create`** — herdr has native git-worktree support, so one command takes a
  branch name to a worktree with its own herdr workspace.
- **`herdr-workspace-close`** — closing a primary workspace that still has linked worktree
  workspaces open asks whether to close the group (`close_group`); without that the group stays
  open.
- **`herdr-pane-read`** / **`herdr-agent-read`** — terminal output into a real Emacs buffer.
  `recent_unwrapped` undoes terminal line-wrapping, which is what makes the result greppable.
- **`herdr-agent-wait`** and **`herdr-pane-wait-for-output`** — asynchronous, so Emacs stays
  responsive. "Tell me when the dev server prints `Listening on`" is one command.
- **`herdr-project`** — focus or create the herdr workspace for the current `project.el` project.
- **`herdr-adopt-shell`** / **`herdr-release-shell`** / **`herdr-promote-shell`** — see Adopting a
  shell, above.

Terminal buffers track their pane's working directory (`herdr-term-track-directory`), so
`find-file` and `compile` from a herdr buffer start in the right place.

## Agent awareness

- **Modeline** — `herdr-agents-mode-line-mode` shows e.g. `herdr:2⏸1✓`. Idle agents are omitted
  deliberately: a count that is always on screen stops being read.
- **`M-x herdr-agents`** — a tree of workspaces and panes with status. `RET` focuses, `p` prompts,
  `r` reads. Event-driven, no timer.
- **Desktop notifications** — off by default. `(setq herdr-notify-statuses '("blocked" "done"))`
  to opt in. Uses `alert` when available.

## Integrations, and agents driving herdr themselves

herdr can be told about agent lifecycle directly instead of inferring it. Without an integration,
status comes from herdr's *detection heuristics* — regexes over the terminal title — so agents
tend to sit at `idle`. With one, they report `idle` / `working` / `blocked` to the socket:

```bash
herdr integration install claude     # writes ~/.claude/hooks/herdr-agent-state.sh
herdr integration status
```

That is what makes the modeline segment, `*herdr-agents*` and `herdr-agent-wait` genuinely useful
rather than approximate. Note it writes to the agent's own config.

Agents can also drive herdr themselves, via herdr's [agent skill](https://herdr.dev/docs/agent-skill/)
— splitting panes, running commands, waiting on output, starting helper agents. **Everything they
do shows up in Emacs**, because it goes through the same server and the same event stream: an
externally issued `herdr pane split` appears in the pickers, an external status report moves the
modeline, an external close removes the pane.

One consequence of the provenance rule: a pane an *agent* creates gets no buffer under
`agent-windows`, since auto-adoption covers only panes herdr.el created — an agent splitting a
pane to run a build should not seize an Emacs window. It is visible in the picker, and going to it
offers to adopt. If the agent starts a *helper agent* there, it becomes attachable and appears in
the agents list and modeline immediately.

## Completion

Pickers are plain `completing-read` over the cache, so they inherit whatever completion stack you
already use. With `marginalia` the annotation shows agent, status, title and directory; with
`orderless` that makes `web claude blocked` a working query. `embark-act` on a pane candidate
offers focus, read, prompt, close and zoom.

## Development

```bash
make test        # hermetic; no herdr required, uses a fake server
make test-live   # needs a running herdr; includes the schema drift test
make compile     # byte-compile, warnings are errors
```

`make test-live` includes a drift test that checks every curated command's method and parameters
against the running server's schema. herdr is young and its API will move; when it does, that test
names the broken command instead of leaving it to fail in front of you. The round-trip test
asserts the session is left exactly as it was found.

**Both suites run in batch, and that is a real blind spot.** A batch Emacs has no frame, so it
cannot catch a mode line rendering `*invalid*`, a command splitting a window, or a transient
entry that was never added. Several bugs got through a green suite and were only found by driving
a real Emacs under a PTY. When changing anything that touches windows, buffers or the mode line,
run it in a real frame as well.

## Design notes

Full design and rationale: [`docs/superpowers/specs/2026-08-01-herdr-el-design.md`](docs/superpowers/specs/2026-08-01-herdr-el-design.md).

## License

GPL-3.0-or-later.
