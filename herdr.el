;;; herdr.el --- Control the herdr terminal workspace manager -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; URL: https://github.com/ejesinsky/herdr.el
;; Version: 0.2.0
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (transient "0.4.0") (ghostel "0"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Drive herdr (https://herdr.dev), a terminal workspace manager for AI
;; coding agents, from Emacs.
;;
;; herdr's terminals live inside Emacs via ghostel, so there is no
;; second terminal application in the loop.  Commands go over herdr's
;; unix socket; a live event stream keeps a cache of the session, which
;; feeds the modeline segment, the `*herdr-agents*' buffer, and the
;; completion pickers.
;;
;; Start with `M-x herdr'.

;;; Code:

(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-term)
(require 'herdr-cmd)
(require 'herdr-agents)

(declare-function project-root "project" (project))
(declare-function project-current "project" (&optional maybe-prompt directory))

(defcustom herdr-protocol-version 22
  "Protocol version this package was written against.
A mismatch warns once rather than refusing to run: declining to work
because herdr bumped a minor is worse than one command misbehaving."
  :type 'integer
  :group 'herdr)

(defvar herdr--protocol-warned nil)

(defun herdr--check-protocol ()
  "Warn once if the server speaks a protocol this package does not know."
  (unless herdr--protocol-warned
    (when-let* ((pong (ignore-errors (herdr-rpc-call "ping")))
                (protocol (alist-get 'protocol pong)))
      (unless (equal protocol herdr-protocol-version)
        (setq herdr--protocol-warned t)
        (message
         "herdr.el: server speaks protocol %s, this package targets %s; \
some commands may misbehave"
         protocol herdr-protocol-version)))))

;;;###autoload
(defun herdr-start ()
  "Bring up herdr inside Emacs: server, terminals, and the event stream."
  (interactive)
  (herdr-term-ensure)
  (herdr--check-protocol)
  (unless (herdr-state-running-p)
    (herdr-state-start))
  ;; agent-windows needs the cache before it can decide what to attach.
  (when (eq herdr-terminal-backend 'agent-windows)
    (herdr-term-ensure)))

;;;###autoload
(defun herdr-stop ()
  "Stop following herdr and kill its Emacs-side buffers.
The herdr server keeps running; agents are unaffected."
  (interactive)
  (herdr-term-teardown)
  (herdr-state-stop))

;;;###autoload
(defun herdr-project ()
  "Focus the herdr workspace for the current project, creating it if absent."
  (interactive)
  (herdr-start)
  (let* ((root (or (when (fboundp 'project-current)
                     (when-let* ((project (project-current nil)))
                       (expand-file-name (project-root project))))
                   default-directory))
         (existing (herdr-state-workspace-for-directory
                    (herdr-state-current) root)))
    (if existing
        (herdr-rpc-call "workspace.focus"
                        `((workspace_id . ,(alist-get 'workspace_id existing))))
      (herdr-rpc-call "workspace.create"
                      `((cwd . ,root)
                        (label . ,(file-name-nondirectory
                                   (directory-file-name root))))))
    (herdr-term-display)))

;;;###autoload
(defun herdr ()
  "Start herdr if needed and open its command menu."
  (interactive)
  (herdr-start)
  (herdr-term-display)
  (call-interactively 'herdr-transient))

;; Loaded last: herdr-transient autoloads `herdr-project', which is
;; defined above, so requiring it here rather than at the top avoids a
;; circular load while still making the whole command surface available
;; as soon as this file is loaded.  A lazy require inside `herdr' would
;; leave `M-x herdr-transient' broken until `M-x herdr' had run once.
(require 'herdr-transient)

(provide 'herdr)
;;; herdr.el ends here
