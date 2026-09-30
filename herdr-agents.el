;;; herdr-agents.el --- Agent status surface for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Knowing which agents are blocked or finished without going to look.
;;
;; Two surfaces, both fed by `herdr-state-change-hook' and neither doing
;; any I/O: a modeline segment that is always on, and `*herdr-agents*',
;; a tree you open when the segment says something interesting.  Desktop
;; notifications are available but off, because an agent changing state
;; is not by default worth interrupting for.

;;; Code:

(require 'subr-x)
(require 'herdr-state)
(require 'herdr-cmd)

(defcustom herdr-notify-statuses nil
  "Agent statuses that raise a desktop notification.
Nil means never.  A sensible opt-in is (\"blocked\" \"done\")."
  :type '(repeat string)
  :group 'herdr)

(defcustom herdr-agents-buffer-name "*herdr-agents*"
  "Name of the agent status buffer."
  :type 'string
  :group 'herdr)

(defconst herdr-agents-status-glyphs
  '(("working" . "▶") ("blocked" . "⏸") ("done" . "✓") ("idle" . "·"))
  "Glyph shown for each agent status.")

;;; Modeline segment

(defun herdr-agents--counts (state)
  "Return an alist of (STATUS . COUNT) for the agents in STATE."
  (let ((counts nil))
    (dolist (pane (herdr-state-agents state))
      (let ((status (or (alist-get 'agent_status pane) "unknown")))
        (setf (alist-get status counts nil nil #'equal)
              (1+ (or (alist-get status counts nil nil #'equal) 0)))))
    counts))

(defun herdr-agents--segment (state)
  "Return the modeline string for STATE, or an empty string.
Idle agents are omitted: a count that is always on screen stops being
read.  Only the states worth acting on appear."
  (let* ((counts (herdr-agents--counts state))
         (parts (delq nil
                      (mapcar
                       (lambda (status)
                         (when-let* ((n (alist-get status counts
                                                   nil nil #'equal)))
                           (when (> n 0)
                             (format "%d%s" n
                                     (alist-get status
                                                herdr-agents-status-glyphs
                                                "?" nil #'equal)))))
                       '("blocked" "working" "done")))))
    (if parts (concat "herdr:" (string-join parts)) "")))

(defvar herdr-agents-mode-line-string ""
  "Cached modeline segment, refreshed from the state change hook.")
(put 'herdr-agents-mode-line-string 'risky-local-variable t)

(defun herdr-agents--refresh-segment (&rest _)
  "Recompute the modeline segment and redisplay."
  (setq herdr-agents-mode-line-string
        (let ((text (herdr-agents--segment (herdr-state-current))))
          (if (string-empty-p text)
              ""
            (concat " "
                    (propertize text
                                'help-echo "herdr agents (mouse-1: details)"
                                'mouse-face 'mode-line-highlight
                                'local-map
                                (let ((map (make-sparse-keymap)))
                                  (define-key map [mode-line mouse-1]
                                              #'herdr-agents)
                                  map))))))
  (force-mode-line-update t))

(defun herdr-agents--ensure-global-mode-string ()
  "Make `global-mode-string' safe to append a symbol to.

A mode-line construct that is a list beginning with a symbol is read as
a conditional — (SYMBOL THEN ELSE) — not as a list of elements.  So on a
fresh Emacs, where `global-mode-string' is nil, appending our symbol
produced (herdr-agents-mode-line-string), which Emacs evaluated as a
conditional with no branches and rendered as *invalid* in every mode
line.

Leading with an empty string forces the list-of-elements reading.  This
is why Emacs's own `global-mode-string' conventionally starts with \"\"."
  (cond
   ((null global-mode-string) (setq global-mode-string '("")))
   ((not (listp global-mode-string))
    (setq global-mode-string (list "" global-mode-string)))
   ((not (equal (car global-mode-string) ""))
    (setq global-mode-string (cons "" global-mode-string)))))

;;;###autoload
(define-minor-mode herdr-agents-mode-line-mode
  "Show a count of noteworthy herdr agents in the modeline."
  :global t
  :group 'herdr
  (if herdr-agents-mode-line-mode
      (progn
        (herdr-agents--ensure-global-mode-string)
        (add-to-list 'global-mode-string
                     'herdr-agents-mode-line-string t)
        (add-hook 'herdr-state-change-hook #'herdr-agents--refresh-segment)
        (herdr-agents--refresh-segment))
    (setq global-mode-string
          (delq 'herdr-agents-mode-line-string global-mode-string))
    (remove-hook 'herdr-state-change-hook #'herdr-agents--refresh-segment)))

;;; Notifications

(defvar herdr-agents--last-status (make-hash-table :test 'equal)
  "Last seen status per pane, so only transitions notify.")

(defun herdr-agents--notify (title body)
  "Raise a desktop notification with TITLE and BODY."
  (cond
   ((fboundp 'alert) (funcall 'alert body :title title))
   ((fboundp 'notifications-notify)
    (funcall 'notifications-notify :title title :body body))
   (t (message "%s: %s" title body))))

(defun herdr-agents--maybe-notify (&rest _)
  "Notify about agents that just entered a status in `herdr-notify-statuses'."
  (when herdr-notify-statuses
    (dolist (pane (herdr-state-agents (herdr-state-current)))
      (let* ((id (alist-get 'pane_id pane))
             (status (alist-get 'agent_status pane))
             (previous (gethash id herdr-agents--last-status)))
        (unless (equal status previous)
          (puthash id status herdr-agents--last-status)
          (when (and previous (member status herdr-notify-statuses))
            (herdr-agents--notify
             (format "herdr: %s is %s" (or (alist-get 'agent pane) id) status)
             (or (alist-get 'terminal_title_stripped pane) id))))))))

;;; The agents buffer

(defvar herdr-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'herdr-agents-visit)
    (define-key map "p" #'herdr-agents-prompt)
    (define-key map "r" #'herdr-agents-read)
    (define-key map "g" #'herdr-agents-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `herdr-agents-mode'.")

(define-derived-mode herdr-agents-mode special-mode "herdr-agents"
  "Major mode listing herdr agents and their status."
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-agents-refresh))))

(defun herdr-agents--pane-at-point ()
  "Return the pane id recorded on the current line."
  (or (get-text-property (line-beginning-position) 'herdr-pane-id)
      (user-error "herdr: no agent on this line")))

(defun herdr-agents-visit ()
  "Focus the agent on this line, and show its buffer if one exists."
  (interactive)
  (let ((id (herdr-agents--pane-at-point)))
    (herdr-pane-focus id)
    (when-let* ((buffer (and (fboundp 'herdr-term-buffer-for-pane)
                             (herdr-term-buffer-for-pane id))))
      (pop-to-buffer buffer))))

(defun herdr-agents-prompt ()
  "Prompt the agent on this line."
  (interactive)
  (herdr-agent-prompt (read-string "Prompt: ") (herdr-agents--pane-at-point)))

(defun herdr-agents-read ()
  "Read the agent on this line into a buffer."
  (interactive)
  (herdr-agent-read (herdr-agents--pane-at-point) "recent_unwrapped"))

(defun herdr-agents--restore-suffix (pane)
  "Return a short note when PANE failed to restore, or an empty string.
herdr 0.9.2 records that on `PaneInfo.restore_error'."
  (let ((err (alist-get 'restore_error pane)))
    (if (and (stringp err) (not (string-empty-p err)))
        (format "  [restore failed: %s]" err)
      "")))

(defun herdr-agents--insert-tree (state)
  "Insert the workspace, tab and pane tree for STATE."
  (dolist (workspace (herdr-state-workspaces state))
    (let ((workspace-id (alist-get 'workspace_id workspace)))
      (insert (propertize (format "%s\n" (or (alist-get 'label workspace)
                                             workspace-id))
                          'face 'bold))
      (dolist (pane (herdr-state-panes state))
        (when (equal workspace-id (alist-get 'workspace_id pane))
          (let* ((id (alist-get 'pane_id pane))
                 (shell (herdr-state-shell-pane-p pane))
                 (agent (if shell "shell*" (alist-get 'agent pane)))
                 (status (unless shell (alist-get 'agent_status pane)))
                 (glyph (if shell "~"
                          (alist-get status herdr-agents-status-glyphs
                                     " " nil #'equal))))
            (insert
             (propertize
              (format "  %s %-10s %-9s %-12s %s%s\n"
                      glyph (or agent "shell") (or status "")
                      id
                      (or (alist-get 'terminal_title_stripped pane) "")
                      (herdr-agents--restore-suffix pane))
              'herdr-pane-id id)))))
      (insert "\n"))))

(defun herdr-agents-refresh ()
  "Redraw the agents buffer from the cache."
  (interactive)
  (when-let* ((buffer (get-buffer herdr-agents-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (herdr-agents--insert-tree (herdr-state-current))
        (goto-char (point-min))
        (forward-line (1- line))))))

;;;###autoload
(defun herdr-agents ()
  "Show herdr's agents and their status."
  (interactive)
  (let ((buffer (get-buffer-create herdr-agents-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-agents-mode) (herdr-agents-mode))
      (add-hook 'herdr-state-change-hook #'herdr-agents--refresh-hook))
    (herdr-agents-refresh)
    (pop-to-buffer buffer)))

(defun herdr-agents--refresh-hook (&rest _)
  "Refresh the agents buffer, if it is still alive."
  (if (get-buffer herdr-agents-buffer-name)
      (herdr-agents-refresh)
    (remove-hook 'herdr-state-change-hook #'herdr-agents--refresh-hook)))

(add-hook 'herdr-state-change-hook #'herdr-agents--maybe-notify)

(provide 'herdr-agents)
;;; herdr-agents.el ends here
