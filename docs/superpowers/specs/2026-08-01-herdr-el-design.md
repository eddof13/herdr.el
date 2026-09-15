# herdr.el — Design

Date: 2026-08-01
Status: Implemented (2026-08-01). Spike results folded in; see Protocol facts.

## Summary

An Emacs package that controls [herdr](https://herdr.dev) — a terminal workspace manager for AI
coding agents — through its local unix-socket JSON API. herdr's terminals are hosted inside Emacs
via [ghostel](https://github.com/dakra/ghostel); Emacs is the only herdr frontend. A
[transient](https://github.com/magit/transient) menu drives the session, and a live event stream
feeds a modeline segment and a status buffer.

herdr never runs outside Emacs. Two terminal backends are supported, sharing everything except
how terminals are hosted:

- **`session`** — one ghostel buffer running the herdr TUI client. herdr owns layout.
- **`agent-windows`** — one ghostel buffer per agent, each running `herdr agent attach`. Emacs
  owns layout; herdr is a headless process and session manager.

Target environment: Emacs 30.2, herdr 0.9.0 (protocol 22), macOS.

## Goals

Four capabilities, all in v1. They are not four features — they are four thin layers over one
substrate (RPC + snapshot cache + event stream), so the marginal cost of each after the core is
small.

1. **Command surface.** Drive herdr from transient instead of its keybindings or CLI.
2. **Agent awareness.** Know which agents are blocked or done without looking.
3. **Output into Emacs.** Pane and agent output as real buffers — greppable, yankable.
4. **Navigation.** Jump to any pane, workspace, or agent by name via `completing-read`.

## Non-goals

Reachable through the generic `herdr-call` escape hatch, but not given curated commands:
`plugin.*`, `pane.graphics.*`, `integration.*`, `server.stop`, remote sessions (`--remote`),
named sessions.

Excluded entirely:

- **Running herdr outside Emacs.** Explicitly rejected. There is no "control a terminal-hosted
  herdr from Emacs" fallback; if a backend does not work, the other backend is the answer.
- **Multi-session.** One global herdr session; herdr workspaces are the per-project unit.
- **Mirroring herdr's layout tree into Emacs windows.** See the `agent-windows` section — Emacs
  owns layout under that backend, so the layout tree is simply unused. This is a deliberate
  simplification, not an omission.
- **herdr-plugin-pushes-into-Emacs.** herdr's plugin API could call into Emacs, and
  `ghostel-eval-cmds` already provides the hook. Interesting, but a separate package.

## Decisions and rationale

### Emacs is the only herdr frontend

herdr's TUI is never displayed outside Emacs. Rejected alternatives:

- **Emacs as a second client alongside a terminal herdr.** Focus is server-side state, so
  focusing a pane from Emacs would move focus in the other client too.
- **Pure socket controller with the TUI left in a standalone terminal.** Rejected by the user
  outright. This removes what would otherwise have been the natural fallback if terminal hosting
  performed badly, which is why two backends exist instead.

### Two terminal backends rather than one

Phases 1 and 3–7 of this design are identical under both backends: the socket core, state cache,
transient, pickers, agents buffer, and escape hatch do not care how terminals are hosted. Only the
terminal layer differs. Making it an interface costs little and avoids betting the package on an
unmeasured performance question.

`session` ships first because it is roughly 60 lines and certainly works. `agent-windows` is the
better endgame and is a planned second backend, not a speculative one — its mechanism has been
verified against a live server (see Protocol facts).

**`session`.** One ghostel buffer runs the `herdr` client. Simple, and plain non-agent shell panes
work. Costs: **two VT layers** (pane output → herdr's VT compositor → PTY → libghostty-vt), a
26-column herdr sidebar consuming Emacs width, and herdr's keybindings competing with Emacs.

**`agent-windows`.** One ghostel buffer per agent pane, each running `herdr agent attach <pane>`.
Buffers are created and reaped from `pane_agent_detected` and `pane_closed` events. Benefits: a
**single VT layer**, native Emacs windows and keybindings, no sidebar overhead, and — the thing
plain ghostel cannot do — **agents survive Emacs exiting**, because the herdr server is a daemon.
Cost: only panes with a detected agent are attachable, so plain shells fall outside it. That is
an acceptable division of labor; herdr is an agent manager, and `ghostel-project` already covers
shells.

### One global session; herdr workspaces are projects

herdr already names workspaces by cwd and persists them across restarts. A session-per-project
scheme would duplicate that concept one level up and split agents across servers, turning "which
agents are blocked" into N queries. `herdr-project` focuses or creates the workspace for
`(project-root)`.

### Curated transient plus a schema-driven escape hatch

herdr exposes 103 methods with a complete, typed JSON Schema. Three options were considered:

- **Thin CLI wrapper** (shell out to `herdr pane split …`). Rejected: ~50ms per spawn, and the
  CLI has no long-lived subscribe, so the event-driven half of the goals dies or degrades to
  polling.
- **Full codegen** of all 103 transient prefixes. Rejected: a 103-entry generated menu is a
  directory listing, not a UI. Generated infixes cannot know that `pane_id` should default to the
  focused pane or offer a labeled picker. Curation would end up layered on top anyway, leaving
  both to maintain.
- **Curated transient + runtime schema** (chosen). ~27 hand-written commands with real
  ergonomics, plus the schema loaded at runtime for two purposes:
  1. `M-x herdr-call` — `completing-read` over all 103 methods, params prompted generically from
     their schema. Full coverage, no generated menus, roughly 120 LOC.
  2. A drift test asserting every curated command's method and params still exist in the live
     schema, so herdr releases surface as a failing test rather than a runtime `not_found`.

## Protocol facts

Established by probing a live herdr and by the published socket-API schema, not from memory.

### Socket and RPC

| Fact | Consequence for the design |
|---|---|
| **One request per connection.** Server writes the response, then EOF. | No id-correlation table, no multiplexing, no reconnect logic on the command path. Fresh socket per call; unix-socket connect cost is negligible, so no pooling. |
| `events.subscribe` holds the connection open. Acks with `{"id":…,"result":{"type":"subscription_started"}}`, then streams NDJSON event envelopes. Lifecycle subscriptions start live and do not replay retained history. | Subscribe first, wait for the ack, buffer, snapshot, apply the buffer. Reconnect repeats that bootstrap. |
| Global subscriptions require no `pane_id`. `pane_created` and `pane_updated` carry full `PaneInfo`, including `agent_status`. | No per-pane subscription bookkeeping — subject to the open question below. |
| `pane.agent_status_changed` and `pane.scroll_changed` subscriptions **require** `pane_id`; `pane.output_matched` requires `pane_id`, `source`, and `match`. | Per-pane subscriptions are the fallback path, not the default. |
| `layout_updated` carries the full layout: pane rects and splits. | Used by `session` backend only incidentally; unused by `agent-windows`. |
| `pane.current` works with no environment variables — returns the focused pane. | Emacs does not need to inherit herdr pane env. Transient scope always defaults correctly. |
| Errors: `{"id":"…","error":{"code":"invalid_request","message":"…"}}`. | Structured; map `code` onto an Emacs condition. |
| `ping` returns `{"version","protocol","capabilities":{"live_handoff":true,"detached_server_daemon":true,"endpoint_protocol_generation":1,…}}`. | Feature-detect via capabilities rather than version-sniffing. Warn on protocol mismatch, do not refuse. |
| Enums: `ReadSource` = `visible｜recent｜recent_unwrapped｜detection`; `ReadFormat` = `text｜ansi`; `SplitDirection` = `right｜down`; `AgentStatus` = `idle｜working｜blocked｜done｜unknown`. | Drive infix `:choices` from the schema. |
| 26 event kinds; 103 methods; protocol 22. | Schema is complete enough for generic param prompting. |
| CLI's `herdr pane run` has no API method. | Implement as `pane.send_text` with a trailing newline. |

### `herdr agent attach` — the `agent-windows` mechanism

| Question | Verified answer |
|---|---|
| Streams a single pane full-screen? | **Yes.** Enters altscreen (`?1049h`), enables mouse tracking (1000/1002/1003/1006), clears and drives its own render loop. Exactly the stream a ghostel buffer wants. |
| Coexists with a session-level client? | **Yes.** Attaching to a pane while a session client was attached worked and left session state unchanged. |
| Two attaches to the *same* pane? | **No.** Exclusive — the second exits rc=1 with no output. This matches the intended one-buffer-per-pane model; `--takeover` exists for stealing. |
| Plain shell pane (no detected agent)? | **No.** Returns `{"error":{"code":"agent_not_found"}}`. Only detected agents are attachable. |
| Agents survive the client exiting? | **Yes.** Server is a daemon (`detached_server_daemon: true`). |
| Does `pane.report_agent` make a shell pane attachable? | **Yes.** Reporting any agent name on a plain shell pane makes `agent attach` accept it, and the resulting ghostel buffer renders and updates live. Verified twice. |
| Do OSC 7 / OSC 133 survive herdr's VT? | **No.** herdr consumes them, as a multiplexer should. An earlier probe appeared to show otherwise; it was matching the shell's own echo of the `printf` command line, not a forwarded escape. Re-run from a script file and matching the real `ESC ]7;` byte: not forwarded. |
| Does herdr track cwd itself? | **Yes**, `pane.cwd` follows a `cd` within about a second — but it is never announced. A `cd` produces no `pane_updated`, only two dozen `layout_updated`. Directory tracking therefore polls `pane.list`, debounced off the event stream with a slow backstop timer. |
| Is adoption reversible? | **Yes.** `pane.release_agent` (which requires `source` *and* `agent`) clears the reported agent and makes the pane unattachable again. Neither adoption nor release is reliably announced, so both resync explicitly. |
| How does herdr's sidebar render an adopted shell? | As one row in its **agents** section labelled with the reported name, e.g. `shell`. Non-agent panes are not listed in the sidebar at all, so there is no alternative row it could occupy. |

### Open question, to be settled by spike, not by assumption

Whether `pane_updated` fires on **agent status** transitions specifically. The probe pane held no
agent, so only `pane_agent_detected` was observed. If `pane_updated` does not cover status
changes, the fallback is per-pane `pane.agent_status_changed` subscriptions maintained against
`pane_created` and `pane_closed` — more bookkeeping, identical result. Resolved in phase 0,
before `herdr-agents.el` is written.

## Architecture

```
Emacs
├── terminal backend (one of)
│   ├─ session:       *herdr* ghostel buffer ── PTY ── herdr TUI client
│   └─ agent-windows: *herdr: <agent>* buffer ── PTY ── herdr agent attach   (one per agent)
│
├── herdr-rpc   ── one-shot unix socket ──┐
└── herdr-state ── long-lived socket ─────┴── herdr server (daemon)
                    (events.subscribe)
```

Two independent channels to the same server. Transient issues an RPC, the server mutates state,
the terminal backend repaints, and the event stream tells Emacs what changed.

### Modules

Each file has one purpose and a stated dependency direction. Nothing depends upward.

| File | Purpose | Depends on |
|---|---|---|
| `herdr-rpc.el` | Socket transport, NDJSON framing, one-shot call (sync + async), error mapping | — |
| `herdr-schema.el` | Load and cache `herdr api schema --json`; generic param prompting; drift-test support | `herdr-rpc` |
| `herdr-state.el` | Snapshot cache, event connection, reducer, change hook | `herdr-rpc` |
| `herdr-term.el` | Backend interface; `session` and `agent-windows` implementations | `herdr-state`, ghostel |
| `herdr.el` | Entry point, session lifecycle, autoloads | all |
| `herdr-cmd.el` | The ~27 curated command wrappers | `herdr-rpc`, `herdr-state` |
| `herdr-select.el` | `completing-read` pickers, marginalia annotators, embark keymaps, consult source | `herdr-state` |
| `herdr-transient.el` | Transient prefixes | `herdr-cmd`, `herdr-select` |
| `herdr-agents.el` | `*herdr-agents*` buffer and modeline segment | `herdr-state` |

### herdr-rpc

`herdr-rpc-call` opens `make-network-process :family 'local`, writes one JSON line, reads to EOF,
parses with `json-parse-string`. Because the protocol is one-shot, the synchronous path is honest
— there is no pending async reply that could interleave. An async variant takes a callback, used
for anything that blocks server-side: `agent.wait`, `pane.wait_for_output`.

### herdr-state

Holds one snapshot — workspaces, tabs, panes, agents, layouts — hydrated by `session.snapshot` at
connect and then mutated incrementally by the event stream. Exposes a single
`herdr-state-change-hook`, called with the event kind.

Everything downstream (modeline, agents buffer, pickers, terminal backends) reads the cache and
never issues its own RPC. `herdr-state-resync` forces a fresh snapshot; the event reader calls it
automatically after any reconnect, because events missed during a gap cannot be replayed and
incremental state is untrustworthy afterward.

The reducer is a pure function of (state, event) so it can be tested without a socket.

## Terminal backends

`herdr-terminal-backend` is a defcustom, either `session` or `agent-windows`. The interface is
four functions: ensure, teardown, buffer-for-pane, and display.

### `session`

`M-x herdr` is idempotent and, in order: pings the socket; starts the server if dead; ensures a
`*herdr*` ghostel buffer is running the `herdr` client; connects the event stream; displays the
buffer.

**Window policy.** herdr renders a 26-column sidebar plus panes, so a narrow window leaves it
very little room. `herdr-display-action` defaults to `(display-buffer-full-frame)` and can be
rebound to a side window or dedicated frame. ghostel propagates resize to the PTY so herdr
reflows, but the sidebar width does not shrink.

**Detach** is killing the ghostel buffer. The server survives. Reattach with `M-x herdr`.

**Handoff.** `live_handoff: true` is advertised and a `server.live_handoff` method exists. What
happens when a second session-level client attaches is a phase-0 spike, deliberately unspecified
here.

### `agent-windows`

One ghostel buffer per agent pane, named `*herdr: <label>*`, running `herdr agent attach <pane_id>`.

- **Lifecycle is event-driven.** `pane_agent_detected` creates a buffer; `pane_closed` and
  `pane_exited` reap it. Reconciliation against the state cache runs after every resync, so a
  reconnect gap cannot leave orphans or gaps.
- **Attach is exclusive per pane.** If attach fails because another client holds the pane, prompt
  before retrying with `--takeover` rather than stealing silently.
- **Emacs owns layout.** herdr's layout tree is not consulted. No geometry sync, no window churn.
- **Plain shell panes are not represented.** They remain reachable through `pane.read`,
  `pane.send_text`, `pane.wait_for_output`, and the transient, but have no buffer.
  `ghostel-project` covers interactive shells. Rationale below.
- **Restart recovery.** On `M-x herdr`, reconcile: every agent in the snapshot gets a buffer.
  Agents started before Emacs launched are picked up automatically.

#### Why plain shells stay in ghostel

Hosting shells in herdr **is possible**, contrary to the first version of this section.
`pane.report_agent` marks any pane as having an agent, after which `agent attach` accepts it and
ghostel renders it live; the `agent-windows` verification was in fact performed against a plain
shell pane treated this way.  So the question is not feasibility but cost.

What hosting shells in herdr would buy: survival across an Emacs restart (a plain ghostel shell is
a child of Emacs and dies with it); one uniform model instead of two kinds of terminal buffer;
`pane.wait_for_output` and `pane.read` on shells; workspace grouping alongside agents; and remote
shells later via `herdr --remote`.

What it costs, now that the OSC question is settled:

- **Directory tracking: no loss.**  herdr consumes OSC 7, but it also tracks cwd itself and
  publishes `cwd` and `foreground_cwd` per pane, updated live.  Setting `default-directory` from
  the cache replaces the OSC path and works under both backends.
- **Prompt navigation (OSC 133): lost.**  herdr exposes no prompt marks, so there is nothing to
  reconstruct them from.
- **`ghostel-eval-cmds`: lost.**  Its OSC trigger does not survive herdr's VT.  In the target
  environment this is configured to launch `magit-status-setup-buffer` from a shell command, so
  it is a concrete loss.  herdr's plugin API could serve a similar role, but through a different
  mechanism.
- **Agent-list pollution:** a reported shell appears as an agent in herdr's own sidebar.  Choosing
  a distinct agent name — `shell` was accepted and round-tripped — lets herdr.el filter it out of
  the modeline count and agents buffer, but herdr's own UI still shows it.

Resolution: shells are not adopted **wholesale**, but `herdr-adopt-shell` makes it a per-pane
choice.  The default stays as designed — `agent-windows` shows agents, and `ghostel-project`
covers ordinary shells — while a pane you specifically want to watch in Emacs and keep across a
restart can be adopted deliberately and released again.

Adopted shells are attachable but are not agents: `herdr-state-attachable` drives reconciliation
so they get buffers, while `herdr-state-agents` excludes them so they stay out of the modeline
count, the agent picker and notifications.  Directory tracking applies to them as it does to
agent buffers.

## Command surface

### Transient

Magit-style root prefix with sub-prefixes. The prefix carries a **scope** — the target pane —
shown in the header, defaulting to `pane.current`. `C-u` or an infix retargets via picker. This
defaulting and labeling is precisely what codegen cannot do, and is the justification for the
curated layer.

```
M-x herdr        [w1:p1  web/1  claude:idle]
 Navigate            Pane  (p)        Agent  (a)
  j pane              s split right    p prompt
  J agent             S split down     r read → buffer
  w workspace         k close          w wait until…
  t tab               z zoom           s start
                      = resize         e explain
                      o wait output…
 Session             Tab   (t)        Workspace (w)
  g resync            c create         c create
  a attach/detach     k close          k close
  ? status            r rename         r rename
                                       W worktree (W)
 x  any method…  (herdr-call, all 89)
```

Roughly 27 curated commands. Four worth calling out:

- **`worktree.*`** — herdr has native git-worktree support (`list`, `create`, `open`, `remove`).
  Creating a worktree and its herdr workspace in one command is expected to be the highest-value
  command in the package.
- **`pane.read` into a buffer** — `recent_unwrapped` is the source you want for grepping;
  `ansi-color-apply-on-region` when `format` is `ansi`.
- **`agent.wait`** — async and callback-driven, so it does not block Emacs. Notification fires on
  transition.
- **`pane.wait_for_output`** — wait for a regex match in any pane, async, with a callback.
  "Notify me when the dev server prints `Listening on`" becomes one command. Curated for **any**
  pane, not just agents, so it already works on shell panes and will keep working if shells ever
  gain buffers. Requires `pane_id`, `source`, and `match`; `lines`, `strip_ansi`, and `timeout_ms`
  optional.

### Pickers

Plain `completing-read` over the state cache. Candidates are pane ids; a `marginalia` annotator
renders label, cwd, agent, and status, so `orderless` makes `web claude blocked` a valid query.
An `embark` keymap on the `herdr-pane` category makes `embark-act` open the pane transient scoped
to that candidate. A `consult-herdr` source is added to `consult-buffer-sources`.

No bespoke UI: roughly 80 lines of annotator and keymap over the existing
vertico/consult/embark/marginalia/orderless stack.

## Notifications

- **Modeline segment**, always on. `herdr:2⏸1✓` derived from the state cache, in
  `global-mode-string`. No RPC; updates on `herdr-state-change-hook`. Clicking opens the agents
  buffer.
- **`*herdr-agents*` buffer**, the thing you open. `magit-section` tree: workspaces → tabs →
  panes, with agent and status per row. `RET` focuses the pane (and selects its buffer under
  `agent-windows`), `p` prompts it, `r` reads it. Event-driven refresh, no timer.
- **Desktop banner**, opt-in via `herdr-notify-statuses`, default `nil`. Soft-depends on
  `alert.el` when present, otherwise a small `notifications-notify` fallback. No hard dependency.
- Echo-area messages and sound are off by default and configurable.

herdr's own `notification.show` renders inside herdr's UI and is treated as redundant with the
Emacs-side path.

## Error handling

A single condition, `herdr-error`, carries the server's `code` so callers branch on `not_found`
versus `invalid_request` rather than parsing message strings.

| Failure | Behavior |
|---|---|
| Socket missing or connection refused | Not an error for `M-x herdr` — it offers to start the server. Other commands signal "herdr not running". |
| Protocol version ≠ 17 | Warn once per session with both versions and continue. Refusing to run on a minor bump is worse than one broken command. |
| `{"error":{…}}` response | Signal `herdr-error` with code and message. |
| `not_found` on a cached pane id | Auto-resync once and retry. A stale cache is expected, not user-facing. |
| `agent_not_found` on attach | Under `agent-windows`, means the pane has no detected agent — skip it, do not error. |
| Attach refused (pane already held) | Prompt before retrying with `--takeover`. Never steal silently. |
| Event stream EOF | Reconnect with backoff (1s → 30s), then full resync, then backend reconciliation. |
| Terminal buffer killed | Detached state, not an error. Reflected in the segment; server keeps running. |
| Schema cache stale | Keyed on the version reported by `ping`; a version change invalidates it. |

## Testing

**Hermetic unit tests, no herdr required.** Emacs acts as the server via
`make-network-process :server t :family 'local` on a temp socket, replaying canned NDJSON. This
covers RPC framing, one-shot EOF semantics, error mapping, event parsing, and state reduction.
Fixtures are real captures taken during design, including a genuine `invalid_request` error
response (missing required `pane_id` on a `pane.agent_status_changed` subscription) and the
`subscription_started` ack.

**Reducer regression test.** Feed the recorded event sequence captured during design (30 events
across a split/rename/send-text/close cycle) into the pure reducer and assert the resulting cache
equals the `session.snapshot` taken afterward.

**Backend reconciliation test.** Pure function: given a state cache and a set of live buffers,
compute buffers to create and reap. Tested without ghostel or a server.

**Live tests, tagged `:live`, skipped by default:**

- **Drift test** — every curated command's method and params still exist in
  `herdr api schema --json`. This is what keeps 27 hand-written wrappers honest across herdr
  releases.
- **Round-trip** — split, rename, send text, read it back, close; assert the session is left
  exactly as found.

## Phases

Phase 0 informs the default backend but no longer gates the architecture, since neither outcome
sends herdr outside Emacs.

| # | Phase | Gate |
|---|---|---|
| 0 | Spikes: VT throughput under `session`; session-level handoff semantics; whether `pane_updated` carries agent-status transitions; whether OSC survives herdr's VT | Answers recorded before any code |
| 1 | `herdr-rpc`, `herdr-schema`, `herdr-state`, hermetic tests | Reducer test green |
| 2 | `herdr-term` interface + `session` backend; `herdr.el` entry and lifecycle | `M-x herdr` attaches |
| 3 | `herdr-cmd`, `herdr-select` | Pickers work with marginalia and embark — goals 3 and 4 complete |
| 4 | `herdr-transient` | Daily-usable — goal 1 complete |
| 5 | `herdr-agents`, modeline segment | Goal 2 complete |
| 6 | `herdr-call`, drift test | All 103 methods reachable |
| 7 | `agent-windows` backend | Both backends selectable; reconciliation test green |
| 8 | README, package headers, autoloads | Publishable |

### Phase 0 spike detail

1. **VT throughput under `session`.** Dump a large build log into a herdr pane with the herdr TUI
   running inside ghostel. Two VT layers are on that path. A poor result makes `agent-windows`
   the recommended default rather than invalidating anything.
2. **Session-level handoff.** Determine what `server.live_handoff` does and what happens when a
   second session client attaches.
3. **Agent status events.** Run a real agent, watch the global stream, determine whether
   `pane_updated` carries status transitions or whether per-pane subscriptions are required.
4. **OSC survival.** *Answered: they do not survive.* herdr consumes OSC 7 and OSC 133.
   Beware the trap this spike fell into first: sending the escapes inline makes the shell echo
   the command text, which contains the same characters and reads as a false positive.  Emit
   from a script file and match the real `ESC ]7;` byte.  Consequence: `agent-windows` buffers
   have no OSC-derived directory tracking either — but herdr publishes `cwd` per pane and
   updates it live, so `default-directory` can be driven from the cache instead.

## Packaging

Personal use first, published to GitHub when good. Structured for that from the start: proper
package headers, multi-file layout, ERT tests, README. No CI or MELPA recipe until publication.
Path: `~/src/herdr.el/`.

Runtime dependencies: Emacs 28.1+ (floor set by ghostel's dynamic-module requirement; `transient`
and `json-parse-string` are both available by then), `transient`, `ghostel`. Soft:
`magit-section`, `marginalia`, `embark`, `consult`, `alert`. No hard dependency on anything not
already installed in the target environment.

---

## Implementation notes and corrections

This document is the design as agreed before the code existed.  It is kept as the record of why
things are shaped the way they are, but several of its assumptions did not survive contact with a
running herdr.  **`README.md` describes current behaviour; where the two disagree, the README is
right.**

What changed:

- **Attaching is lazy.**  The design had reconciliation attach every agent as it appeared.  The
  attach client needs a window when it starts, so that meant `M-x herdr` taking a window per agent
  before being asked for anything.  Panes are attached the first time they are visited instead.
  (The client survives being *hidden* — only a deleted window kills it.)
- **Cache can still drift.**  Lifecycle subscriptions no longer replay, but a disconnect gap or
  a `cd` that never emits `pane_updated` still leaves the cache wrong.  The pane set is
  reconciled against `pane.list` on a poll.
- **Directory changes are never announced.**  herdr tracks cwd accurately but publishes no event
  for it, so tracking polls rather than subscribes.
- **Adoption is implemented, and it outranks detection.**  The design listed shells-in-herdr as
  out of scope.  `herdr-adopt-shell` makes it a per-pane choice — but reporting an agent takes
  lifecycle authority, so an adopted pane keeps its label even once a real agent starts in it.
  Promotion reads the detector's own conclusion via `agent.explain` and relabels.  Releasing
  authority does not restore detection: it binds at agent start and does not re-run.
- **OSC is not forwarded.**  Corrected in Protocol facts above; the original spike was a false
  positive from the shell echoing the command text.
- **One display setting.**  `herdr-display-action` defaulted to taking the whole frame and applied
  only to `M-x herdr`, so the same buffer appeared two ways.  It now defaults to reusing the
  current window and governs every path that shows a herdr buffer.
- **Tabs and adoption are filtered by backend.**  Tabs render nowhere under `agent-windows`;
  adoption buys nothing under `session`.  Neither is offered where it means nothing.
- **Targeting prefers the current buffer.**  The design assumed herdr's focus was the right
  target.  It is server-side and does not follow Emacs, so acting from inside one agent's buffer
  targeted whichever pane was last visited.

Testing gap worth recording: both suites run in batch, which has no frame.  A mode line rendering
`*invalid*`, a command splitting a window, and a menu entry that was never added all passed a
green suite and were found only by driving a real Emacs under a PTY.
