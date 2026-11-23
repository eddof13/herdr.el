;;; herdr-term.el --- Terminal hosting for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (ghostel "0.59.0"))

;;; Commentary:

;; herdr's terminals are hosted inside Emacs, never outside it.  There
;; are two ways to do that and this file implements both behind one
;; interface, because everything else in the package is indifferent to
;; the choice.
;;
;; `session' runs the herdr TUI in a single ghostel buffer.  herdr owns
;; the layout, plain shell panes work, and it is about sixty lines.
;;
;; `agent-windows' runs one ghostel buffer per claimed pane.  herdr 0.9.2
;; attaches that pane with `herdr terminal attach' on its terminal id;
;; `herdr agent attach' remains the fallback when a pane has no terminal
;; id.  Emacs owns the layout and herdr's own layout tree goes unused,
;; so there is no geometry to synchronise.  Claimed panes outlive Emacs
;; because the server is a daemon.
;;
;; Measurements that informed this, taken against a live herdr:
;;
;; - Throughput is not a reason to prefer either.  A 12.2 MB pane dump
;;   reached Emacs as 17 KB under `session' and 24 KB under
;;   `agent-windows'; herdr's VT only emits visible-frame diffs, so it
;;   rate-limits by construction.
;; - `terminal attach' accepts a plain shell.  `agent attach' still
;;   refuses a pane with no agent, which is why an unadopted shell gets
;;   no buffer.
;; - Attachment is exclusive per pane, so a second attach needs
;;   `--takeover'.  We ask first rather than stealing.  The refusal is
;;   not an Elisp error: `ghostel-exec' returns at once and the client
;;   exits with code 1 some 20-60 ms later, so the prompt hangs off
;;   `ghostel-exit-functions', which reports that status on both PTY
;;   backends from ghostel 0.59.0.
;; - The client paints nothing into a zero-sized PTY.  ghostel sizes its
;;   terminal from the displayed window, so buffers are displayed before
;;   the process starts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-state)

(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-mode "ghostel" ())
(defvar ghostel-exit-functions)
(defvar ghostel-kill-buffer-on-exit)

(defcustom herdr-terminal-backend 'session
  "How herdr's terminals are hosted inside Emacs.

`session' runs the herdr TUI in one ghostel buffer and lets herdr own
the layout.  `agent-windows' gives every claimed pane its own ghostel
buffer and lets Emacs own the layout.  A claimed pane has an agent, or
was adopted locally.  Plain shells nobody asked for are not represented."
  :type '(choice (const :tag "One buffer running the herdr TUI" session)
                 (const :tag "One buffer per agent" agent-windows))
  :group 'herdr)

(defcustom herdr-display-action
  '((display-buffer-reuse-window display-buffer-same-window))
  "How herdr buffers are shown, for every path that shows one.

One knob, honoured everywhere: starting herdr, going to a pane, and
attaching all route through it, so the same buffer cannot appear two
different ways depending on which command got you there.

The default reuses the current window.  Rearranging the frame is the
user\='s business — `C-x 2\=', `C-x 3\=', `display-buffer-alist\=' — not
something navigating should do on your behalf.

herdr\='s TUI draws a 26-column sidebar beside its panes and so wants
width, which is advice rather than grounds for bulldozing a layout.  For
the old behaviour of taking the whole frame:

    (setq herdr-display-action \='(display-buffer-full-frame))"
  :type 'sexp
  :group 'herdr)

(defun herdr-term--show (buffer)
  "Show BUFFER according to `herdr-display-action' and select it."
  (pop-to-buffer buffer herdr-display-action))

(defcustom herdr-server-start-timeout 15.0
  "Seconds to wait for a freshly launched herdr server to answer."
  :type 'number
  :group 'herdr)

(defconst herdr-term-session-buffer-name "*herdr*"
  "Buffer that hosts the herdr TUI under the `session' backend.")

;;; Naming and argument construction — pure, so they are testable

(defun herdr-term-agent-buffer-name (pane)
  "Return the buffer name for PANE under the `agent-windows' backend."
  (format "*herdr: %s %s*"
          (or (alist-get 'agent pane) "shell")
          (alist-get 'pane_id pane)))

(defun herdr-term-attach-args (pane takeover)
  "Return argv tail for attaching to PANE, stealing it when TAKEOVER.
PANE is a pane alist or a pane id.  herdr 0.9.2 attaches a plain shell
with `terminal attach' on its terminal id.  `agent attach' remains the
fallback for a pane that has no terminal id."
  (let* ((pane (if (stringp pane)
                   (or (herdr-state-pane (herdr-state-current) pane)
                       `((pane_id . ,pane)))
                 pane))
         (pane-id (alist-get 'pane_id pane))
         (terminal (alist-get 'terminal_id pane)))
    (append (if (and terminal (not (string-empty-p terminal)))
                (list "terminal" "attach" terminal)
              (list "agent" "attach" pane-id))
            (when takeover '("--takeover")))))

(defun herdr-term-session-args ()
  "Return argv tail for the session client, which takes no arguments."
  nil)

(defun herdr-term-reconcile (state buffers)
  "Compare STATE against BUFFERS and return (TO-CREATE . TO-REAP).

BUFFERS is an alist of (PANE-ID . BUFFER).  TO-CREATE holds pane alists
that herdr will attach to but that have no buffer; TO-REAP holds buffers
whose pane is gone or is no longer attachable.  Pure: no processes are
touched.

Attachability, not agenthood, is the criterion — a shell adopted through
`herdr-adopt-shell' gets a buffer too."
  (let* ((agents (herdr-state-attachable state))
         (agent-ids (mapcar (lambda (pane) (alist-get 'pane_id pane)) agents))
         (have-ids (mapcar #'car buffers)))
    (cons
     (seq-remove (lambda (pane)
                   (member (alist-get 'pane_id pane) have-ids))
                 agents)
     (mapcar #'cdr
             (seq-remove (lambda (cell) (member (car cell) agent-ids))
                         buffers)))))

;;; Server lifecycle

(defun herdr-server-live-p ()
  "Return non-nil when the herdr server answers a ping."
  (condition-case nil
      (progn (herdr-rpc-call "ping") t)
    (herdr-error nil)))

(defun herdr-term--bootstrap-server ()
  "Start a herdr client long enough to bring the server up.

herdr has no headless start command, so the server is brought up by
running a client.  Under `session' that client is the UI and stays.
Under `agent-windows' it is only a bootstrap: the server is a daemon
and outlives it, so the buffer is discarded once ping succeeds."
  (let ((buffer (get-buffer-create herdr-term-session-buffer-name)))
    (with-current-buffer buffer (ghostel-mode))
    ;; Under `agent-windows' this client only exists to start the daemon
    ;; and is killed straight after, so showing it would be a flash of a
    ;; window the user never asked for.
    (when (eq herdr-terminal-backend 'session)
      (herdr-term--show buffer))
    (ghostel-exec buffer herdr-executable (herdr-term-session-args))
    (let ((deadline (+ (float-time) herdr-server-start-timeout)))
      (while (and (< (float-time) deadline) (not (herdr-server-live-p)))
        (sit-for 0.2)))
    (unless (herdr-server-live-p)
      (error "herdr server did not come up within %ss"
             herdr-server-start-timeout))
    buffer))

;;; Buffer bookkeeping

(defvar herdr-term--agent-buffers nil
  "Alist of (PANE-ID . BUFFER) for the `agent-windows' backend.")

(defun herdr-term--live-agent-buffers ()
  "Return `herdr-term--agent-buffers' with dead buffers dropped."
  (setq herdr-term--agent-buffers
        (seq-filter (lambda (cell) (buffer-live-p (cdr cell)))
                    herdr-term--agent-buffers)))

(defun herdr-term-select-pane (pane-id)
  "Show PANE-ID, attaching to it first if it is not attached yet.

Focus is server-side state, and under `session' the TUI repaints so the
change is visible.  Under `agent-windows' nothing repaints: each pane is
its own Emacs buffer, so focusing a pane has no visible effect unless
Emacs also selects that buffer.

Attaching happens here rather than in reconciliation because the client
needs a window at startup, so attaching every agent up front would mean
`M-x herdr\=' seizing a window per agent before being asked for anything.
Returns the buffer when it showed one."
  (let ((buffer (herdr-term-buffer-for-pane pane-id)))
    (unless (buffer-live-p buffer)
      (setq buffer (herdr-term--attach-if-possible pane-id)))
    (when (buffer-live-p buffer)
      (herdr-term--show buffer)
      buffer)))

(defun herdr-term--attach-if-possible (pane-id)
  "Attach to PANE-ID now, if this backend attaches and the pane is claimed.
A claimed pane has an agent, or was adopted locally.  herdr 0.9.2 will
attach to either through its terminal id."
  (when (eq herdr-terminal-backend 'agent-windows)
    (when-let* ((pane (herdr-state-pane (herdr-state-current) pane-id))
                ((or (alist-get 'agent pane)
                     (herdr-state-adopted-p pane))))
      (herdr-term--attach pane))))

(defun herdr-term-select-focused ()
  "Select the buffer for whichever pane herdr now considers focused.
Asks the server rather than trusting the cache, because focus may have
moved as a side effect of the command that just ran."
  (when-let* ((pane (ignore-errors
                      (alist-get 'pane_id
                                 (alist-get 'pane (herdr-rpc-call "pane.current")))))) 
    (herdr-term-select-pane pane)))

(defun herdr-term-buffer-for-pane (pane-id)
  "Return the buffer showing PANE-ID, if this backend has one."
  (pcase herdr-terminal-backend
    ('session (get-buffer herdr-term-session-buffer-name))
    ('agent-windows (cdr (assoc pane-id (herdr-term--live-agent-buffers))))))

(defun herdr-term-pane-for-buffer (&optional buffer)
  "Return the pane id BUFFER is showing, or nil if it is not a herdr terminal.

Only meaningful under `agent-windows\=', where the mapping is one buffer
per pane.  Under `session\=' every pane shares one buffer, so the current
buffer says nothing about which pane is meant."
  (when (eq herdr-terminal-backend 'agent-windows)
    (let* ((buffer (or buffer (current-buffer)))
           (id (car (rassq buffer (herdr-term--live-agent-buffers)))))
      ;; Ignore a buffer whose pane has since gone away.
      (when (and id (herdr-state-pane (herdr-state-current) id))
        id))))

(defun herdr-term--attach (pane)
  "Create and start a ghostel buffer attached to PANE.
Returns an existing buffer untouched rather than attaching twice:
attachment is exclusive per pane, so a second attach either fails or
steals the first one's terminal."
  (let* ((pane-id (alist-get 'pane_id pane))
         (existing (herdr-term-buffer-for-pane pane-id)))
    (if (buffer-live-p existing)
        existing
      (herdr-term--attach-1 pane pane-id))))

(defcustom herdr-term-refusal-window 5.0
  "Seconds after starting within which an attach failure is a refusal.

herdr refuses a second attach to a held pane by exiting with code 1
within tens of milliseconds.  A client that ran for longer and then
exited with code 1 failed for some other reason, such as the server
going away, and offering to take the pane over would be wrong."
  :type 'number
  :group 'herdr)

(defvar-local herdr-term--attach-context nil
  "Plist describing the attach client started in this buffer.
Keys are :pane, :takeover and :started (a `float-time').")

(defun herdr-term-refusal-p (event elapsed)
  "Return non-nil when an exit EVENT after ELAPSED seconds is a refusal.

EVENT is the string `ghostel-exit-functions' receives.  From ghostel
0.59.0 both PTY backends report a refused attach as \"exited abnormally
with code 1\", while a clean exit or detach is \"finished\".  Older
ghostel reports \"finished\" for every exit on the native PTY, so no
refusal is ever recognised there; that degrades to no prompt, never to
a wrong one."
  (and (stringp event)
       (numberp elapsed)
       (<= elapsed herdr-term-refusal-window)
       (string-match-p "\\`exited abnormally with code 1\n?\\'" event)))

(defun herdr-term--on-client-exit (buffer event)
  "Offer a takeover when BUFFER's attach client was refused.
Run from `ghostel-exit-functions' with the exit EVENT string."
  (let ((context (and (buffer-live-p buffer)
                      (buffer-local-value 'herdr-term--attach-context buffer))))
    (when (and context
               (not (plist-get context :takeover))
               (herdr-term-refusal-p
                event (- (float-time) (plist-get context :started))))
      ;; ghostel kills BUFFER as soon as this hook returns (when
      ;; `ghostel-kill-buffer-on-exit' is set), so a client restarted in
      ;; it here would die with it.  Prompt once the sentinel is done.
      (run-at-time 0 nil #'herdr-term--offer-takeover
                   (plist-get context :pane) buffer))))

(defun herdr-term--offer-takeover (pane old-buffer)
  "Ask whether to steal PANE, whose attach in OLD-BUFFER was refused."
  (let ((pane-id (alist-get 'pane_id pane)))
    ;; With `ghostel-kill-buffer-on-exit' nil the refused buffer lingers;
    ;; it holds no client, so clear it rather than leave a dead twin.
    (when (buffer-live-p old-buffer)
      (kill-buffer old-buffer))
    (when (y-or-n-p
           (format "Pane %s is already attached elsewhere.  Take it over? "
                   pane-id))
      (herdr-term--attach-1 pane pane-id t))))

(defun herdr-term--attach-1 (pane pane-id &optional takeover)
  "Create and start a ghostel buffer attached to PANE, named for PANE-ID.
With TAKEOVER, steal the pane from any client already attached.

A refused attach is not detected here: the client is asynchronous, so
the refusal arrives as its exit status and `herdr-term--on-client-exit'
asks about a takeover then.  An error signalled here is a failure to
start the client at all, which a takeover would not cure."
  (let ((buffer (get-buffer-create (herdr-term-agent-buffer-name pane))))
    (with-current-buffer buffer (ghostel-mode))
    ;; The buffer needs a window when the client starts: attaching without
    ;; displaying, or with a window that is deleted straight afterwards,
    ;; kills the client and ghostel then kills the buffer.  Being merely
    ;; hidden later is fine — a buried terminal keeps running — so the
    ;; window only has to exist, not persist.  Shown through
    ;; `herdr-display-action\=' like every other path.
    (herdr-term--show buffer)
    (with-current-buffer buffer
      (setq herdr-term--attach-context
            (list :pane pane :takeover takeover :started (float-time)))
      (add-hook 'ghostel-exit-functions #'herdr-term--on-client-exit nil t))
    (condition-case err
        (ghostel-exec buffer herdr-executable
                      (herdr-term-attach-args pane takeover))
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    (herdr-term--set-directory buffer pane)
    (push (cons pane-id buffer) herdr-term--agent-buffers)
    buffer))

(defun herdr-term--rename-stale-buffers ()
  "Rename buffers whose pane has changed identity since they were created.

A pane adopted as a shell and later promoted to a real agent keeps the
same buffer — attachment is still valid, so there is nothing to recreate
— but its name would otherwise still read `shell' forever."
  (dolist (cell (herdr-term--live-agent-buffers))
    (when-let* ((pane (herdr-state-pane (herdr-state-current) (car cell)))
                (wanted (herdr-term-agent-buffer-name pane))
                ((not (equal wanted (buffer-name (cdr cell))))))
      (with-current-buffer (cdr cell)
        ;; Unique suffix rather than an error if the name is taken.
        (rename-buffer wanted t)))))

(defun herdr-term--sync-agent-windows ()
  "Reap buffers whose pane is gone and correct stale names.

Deliberately does not attach.  Attaching requires displaying the buffer
and keeping it displayed, so attaching on every `pane_agent_detected\='
would take a window each time an agent appears.  `herdr-term-select-pane\='
attaches on demand instead."
  (let* ((plan (herdr-term-reconcile (herdr-state-current)
                                     (herdr-term--live-agent-buffers))))
    (dolist (buffer (cdr plan))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (herdr-term--rename-stale-buffers)
    (herdr-term--live-agent-buffers)))

;;; Directory tracking

(defcustom herdr-term-track-directory t
  "Whether terminal buffers follow their herdr pane's working directory.

herdr consumes OSC 7 rather than forwarding it, so ghostel's own
directory tracking cannot see through it.  herdr does track cwd itself,
so `default-directory' is driven from that instead — and unlike OSC it
works under both backends.

It has to be polled.  herdr publishes no event when a pane changes
directory: a `cd' produces only unrelated `layout_updated' traffic, so
there is nothing to subscribe to.  See `herdr-term-directory-interval'."
  :type 'boolean
  :group 'herdr)

(defcustom herdr-term-directory-interval 5.0
  "Seconds between backstop working-directory polls, or nil to disable.

Directories are normally refreshed off the event stream: a `cd' emits no
`pane_updated', but it does emit `layout_updated', which is enough of a
hint to go and look.  That refresh is debounced by
`herdr-term-directory-debounce'.

This timer is only a backstop for a directory change that produces no
events at all.  Each poll is a single `pane.list' over a unix socket and
runs only while herdr terminal buffers exist."
  :type '(choice number (const :tag "Never poll" nil))
  :group 'herdr)

(defcustom herdr-term-directory-debounce 0.4
  "Seconds to coalesce directory refreshes triggered by events.
A single `cd' produced two dozen `layout_updated' events, so refreshing
on each one would mean two dozen round trips for one directory change."
  :type 'number
  :group 'herdr)

(defvar herdr-term--directory-timer nil)
(defvar herdr-term--directory-debounce-timer nil)

(defun herdr-term--poll-directories ()
  "Refresh pane directories, then point buffers at them."
  ;; Guarded only on the stream being up.  It used to also require a
  ;; herdr buffer to exist, which silently disabled the whole poll under
  ;; `agent-windows\=' once attaching became lazy — and with it the pruning
  ;; of panes the server no longer has.  Pruning matters most exactly when
  ;; no buffers are open yet, because that is when the pickers are used.
  (when (herdr-state-running-p)
    (herdr-state-promote-shell-panes)
    (when (herdr-state-reconcile-panes)
      (herdr-term--sync-directories))))

(defun herdr-term--schedule-directory-poll ()
  "Refresh directories shortly, coalescing bursts of events."
  (when herdr-term-track-directory
    (when herdr-term--directory-debounce-timer
      (cancel-timer herdr-term--directory-debounce-timer))
    (setq herdr-term--directory-debounce-timer
          (run-at-time herdr-term-directory-debounce nil
                       (lambda ()
                         (setq herdr-term--directory-debounce-timer nil)
                         (herdr-term--poll-directories))))))

(defun herdr-term--start-directory-timer ()
  "Begin the backstop poll for working-directory changes.
A repeating timer rather than an idle one: idle timers never fire while
something keeps Emacs busy, which is exactly when a long-running command
is changing directories."
  (when (and herdr-term-track-directory
             herdr-term-directory-interval
             (not herdr-term--directory-timer))
    (setq herdr-term--directory-timer
          (run-at-time herdr-term-directory-interval
                       herdr-term-directory-interval
                       #'herdr-term--poll-directories))))

(defun herdr-term--stop-directory-timer ()
  "Stop polling for working-directory changes."
  (dolist (timer (list herdr-term--directory-timer
                       herdr-term--directory-debounce-timer))
    (when timer (cancel-timer timer)))
  (setq herdr-term--directory-timer nil
        herdr-term--directory-debounce-timer nil))

(defun herdr-term--set-directory (buffer pane)
  "Point BUFFER's `default-directory' at PANE's working directory."
  (when-let* (((buffer-live-p buffer))
              (dir (herdr-state-pane-directory pane)))
    (with-current-buffer buffer
      (unless (equal default-directory dir)
        (setq default-directory dir)))))

(defun herdr-term--sync-directories ()
  "Point every terminal buffer at its pane's current directory."
  (when herdr-term-track-directory
    (let ((state (herdr-state-current)))
      (pcase herdr-terminal-backend
        ('session
         ;; One buffer for the whole session, so it follows the focused pane.
         (when-let* ((buffer (get-buffer herdr-term-session-buffer-name))
                     (id (herdr-state-focused-pane-id state))
                     (pane (herdr-state-pane state id)))
           (herdr-term--set-directory buffer pane)))
        ('agent-windows
         (dolist (cell (herdr-term--live-agent-buffers))
           (when-let* ((pane (herdr-state-pane state (car cell))))
             (herdr-term--set-directory (cdr cell) pane))))))))

(defun herdr-term--on-state-change (_kind _data)
  "Resync terminal buffers after a cache change."
  (when (eq herdr-terminal-backend 'agent-windows)
    (herdr-term--sync-agent-windows))
  (herdr-term--sync-directories)
  (herdr-term--schedule-directory-poll))

;;; Interface

(defun herdr-term-ensure ()
  "Make sure this backend's terminals exist, starting the server if needed."
  (require 'ghostel)
  (let ((bootstrap (unless (herdr-server-live-p)
                     (herdr-term--bootstrap-server))))
    ;; Both backends want the hook: one for buffer reconciliation and
    ;; directory tracking, the other for directory tracking alone.
    (add-hook 'herdr-state-change-hook #'herdr-term--on-state-change)
    (prog1
        (pcase herdr-terminal-backend
          ('session
           (or bootstrap
               (let ((buffer (get-buffer herdr-term-session-buffer-name)))
                 (if (buffer-live-p buffer)
                     buffer
                   (herdr-term--bootstrap-server)))))
          ('agent-windows
           ;; The bootstrap client was only there to start the daemon.
           (when (buffer-live-p bootstrap) (kill-buffer bootstrap))
           (herdr-term--sync-agent-windows)))
      (herdr-term--sync-directories)
      (herdr-term--start-directory-timer))))

(defun herdr-term-display ()
  "Show this backend's primary buffer, if it has one.

Under `session' that is the herdr TUI, which is the whole interface and
so is worth showing.  Under `agent-windows' there is no primary buffer —
picking one arbitrarily and popping it would mean `M-x herdr' rearranges
your windows before you have asked for anything.  Buffers are reached
deliberately instead, through the menu, the agents list, or
`consult-buffer'."
  (when (eq herdr-terminal-backend 'session)
    (when-let* ((buffer (get-buffer herdr-term-session-buffer-name)))
      (herdr-term--show buffer))))

(defun herdr-term-teardown ()
  "Kill this backend's buffers.  The herdr server is left running."
  (remove-hook 'herdr-state-change-hook #'herdr-term--on-state-change)
  (herdr-term--stop-directory-timer)
  (pcase herdr-terminal-backend
    ('session
     (when-let* ((buffer (get-buffer herdr-term-session-buffer-name)))
       (kill-buffer buffer)))
    ('agent-windows
     (dolist (cell (herdr-term--live-agent-buffers))
       (kill-buffer (cdr cell)))
     (setq herdr-term--agent-buffers nil))))

(provide 'herdr-term)
;;; herdr-term.el ends here
