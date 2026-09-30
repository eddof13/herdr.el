;;; herdr-transient.el --- Transient menus for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (transient "0.4.0"))

;;; Commentary:

;; The command surface.  Every prefix shows which pane it is about to
;; act on, taken from the cache rather than asked for, so the common
;; case costs no prompting.  A prefix argument on any command retargets
;; through the picker instead.

;;; Code:

(require 'transient)
(require 'herdr-state)
(require 'herdr-term)
(require 'herdr-cmd)
(require 'herdr-select)
(require 'herdr-call)
(require 'herdr-agents)

;; `herdr-project' lives in herdr.el, which loads this file lazily; a
;; top-level require here would be circular.
(declare-function herdr-project "herdr" ())
(autoload 'herdr-project "herdr" nil t)

(defun herdr-transient-tui-p ()
  "Return non-nil when herdr's own layout is on screen.

Tabs are a grouping inside a workspace whose only visual form is the
TUI's tab bar.  Under `agent-windows\=' Emacs owns the layout, so nothing
renders a tab: renaming one changes nothing observable, focusing one is
a roundabout way to reach a pane that `p\=' reaches directly, and closing
one is a confusing way to destroy panes you would close individually.
The whole tab surface is hidden there rather than half of it, which was
worse than either — `herdr-call\=' still reaches the methods.

Workspaces are not filtered: they are keyed by cwd, persist across
restarts, group the agents buffer, and back `herdr-project\=' — they are
herdr's per-project unit, not TUI furniture."
  (eq herdr-terminal-backend 'session))

;; Adoption is the mirror case.  It exists so `agent-windows\=' can show a
;; pane herdr would otherwise refuse to attach to.  Under `session\=' the
;; TUI already shows every pane, so adopting buys nothing and costs a row
;; in herdr\='s own agents list for something that is not an agent — hence
;; `:if-not herdr-transient-tui-p\=' on those three commands.

(defun herdr-transient--origin-buffer ()
  "Return the buffer the menu was opened from.
Descriptions are rendered with the transient\='s own buffer current, so
asking `current-buffer\=' here would lose the pane the user is sitting in
and make the header disagree with what the commands actually target."
  (or (and (boundp 'transient--original-buffer)
           (buffer-live-p transient--original-buffer)
           transient--original-buffer)
      (current-buffer)))

(defun herdr-transient--target ()
  "Return a short description of the pane commands will act on."
  (let* ((state (herdr-state-current))
         (id (herdr-select-current-target (herdr-transient--origin-buffer)))
         (pane (and id (herdr-state-pane state id))))
    (if (not pane)
        "no pane"
      (format "%s  %s%s"
              id
              (or (alist-get 'agent pane) "shell")
              (if-let* ((status (alist-get 'agent_status pane)))
                  (format ":%s" status)
                "")))))

(defun herdr-transient--heading ()
  "Return the root prefix heading."
  (format "herdr  [%s]   C-u on any command retargets"
          (herdr-transient--target)))

;;;###autoload (autoload 'herdr-transient "herdr-transient" nil t)
(transient-define-prefix herdr-transient ()
  "Control the herdr session.

Key scheme, applied throughout: a lowercase noun jumps to that kind of
thing, the same letter uppercased opens its menu.  Verbs are consistent
across every menu — c create, f focus, r read, R rename, k close or
remove, l list.

`?' and `C-h' belong to transient's own help, so status is on `s'.
Worktrees are on `%' and the raw-method escape hatch on `:', matching
where magit puts the same two ideas."
  [:description herdr-transient--heading
   ["Go to"
    ("p" "pane"       herdr-pane-focus)
    ("a" "agent"      herdr-agent-focus)
    ("w" "workspace"  herdr-workspace-focus)
    ("t" "tab"        herdr-tab-focus :if herdr-transient-tui-p)]
   ["Menus"
    ("P" "pane…"      herdr-transient-pane)
    ("A" "agent…"     herdr-transient-agent)
    ("W" "workspace…" herdr-transient-workspace)
    ("T" "tab…"       herdr-transient-tab :if herdr-transient-tui-p)
    ("%" "worktree…"  herdr-transient-worktree)]
   ["Session"
    ("g" "resync"      herdr-state-resync)
    ("l" "agents"      herdr-agents)
    ("s" "status"      herdr-transient-status)
    (":" "any method…" herdr-call)]])

(transient-define-prefix herdr-transient-pane ()
  "Act on a pane."
  [:description herdr-transient--heading
   ["Layout"
    ("s" "split right" herdr-pane-split-right)
    ("S" "split down"  herdr-pane-split-down)
    ("z" "zoom"        herdr-pane-zoom)
    ("=" "resize"      herdr-pane-resize)
    ("m" "swap"        herdr-pane-swap)]
   ["Content"
    ("r" "read → buffer" herdr-pane-read)
    ("c" "clear screen"  herdr-pane-clear)
    ("!" "run command"   herdr-pane-run)
    ("i" "send text"     herdr-pane-send-text)
    ("o" "wait output…"  herdr-pane-wait-for-output)]
   ["Manage"
    ("f" "focus"  herdr-pane-focus)
    ("R" "rename" herdr-pane-rename)
    ("k" "close"  herdr-pane-close)]
   ["Adopt"
    :if-not herdr-transient-tui-p
    ("A" "adopt shell"        herdr-adopt-shell)
    ("U" "unadopt shell"      herdr-release-shell)
    ("G" "drop legacy label"  herdr-promote-shell)]])

(transient-define-prefix herdr-transient-agent ()
  "Act on an agent."
  [:description herdr-transient--heading
   ["Interact"
    ("p" "prompt"        herdr-agent-prompt)
    ("r" "read → buffer" herdr-agent-read)
    ("w" "wait until…"   herdr-agent-wait)]
   ["Manage"
    ("s" "start"   herdr-agent-start)
    ("f" "focus"   herdr-agent-focus)
    ("e" "explain" herdr-agent-explain)]])

(transient-define-prefix herdr-transient-tab ()
  "Act on a tab."
  ["Tab"
   ("c" "create" herdr-tab-create :if herdr-transient-tui-p)
   ("f" "focus"  herdr-tab-focus  :if herdr-transient-tui-p)
   ("R" "rename" herdr-tab-rename :if herdr-transient-tui-p)
   ("k" "close"  herdr-tab-close  :if herdr-transient-tui-p)])

(transient-define-prefix herdr-transient-workspace ()
  "Act on a workspace."
  ["Workspace"
   ("c" "create"      herdr-workspace-create)
   ("p" "for project" herdr-project)
   ("f" "focus"       herdr-workspace-focus)
   ("R" "rename"      herdr-workspace-rename)
   ("k" "close"       herdr-workspace-close)])

(transient-define-prefix herdr-transient-worktree ()
  "Act on git worktrees."
  ["Worktree"
   ("l" "list"   herdr-worktree-list)
   ("c" "create" herdr-worktree-create)
   ("o" "open"   herdr-worktree-open)
   ("k" "remove" herdr-worktree-remove)])

(defun herdr-transient-status ()
  "Report server and cache status in the echo area."
  (interactive)
  (let* ((pong (ignore-errors (herdr-rpc-call "ping")))
         (state (herdr-state-current)))
    (message
     "herdr %s protocol %s | %d workspaces, %d panes, %d agents | stream %s | backend %s"
     (or (alist-get 'version pong) "unreachable")
     (or (alist-get 'protocol pong) "?")
     (length (herdr-state-workspaces state))
     (length (herdr-state-panes state))
     (length (herdr-state-agents state))
     (if (herdr-state-running-p) "up" "down")
     herdr-terminal-backend)))

(provide 'herdr-transient)
;;; herdr-transient.el ends here
