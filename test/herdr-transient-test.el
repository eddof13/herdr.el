;;; herdr-transient-test.el --- Tests for the transient key scheme -*- lexical-binding: t; -*-

;;; Commentary:

;; The key scheme is a promise to muscle memory, so it is asserted
;; rather than left to review.  Three things matter: no prefix binds the
;; same key twice, no prefix steals a key transient reserves for itself,
;; and a verb means the same thing in every menu.

;;; Code:

(require 'ert)
(require 'herdr-transient)
(require 'herdr-cmd)

(defconst herdr-transient-test--prefixes
  '(herdr-transient
    herdr-transient-pane
    herdr-transient-agent
    herdr-transient-tab
    herdr-transient-workspace
    herdr-transient-worktree))

(defun herdr-transient-test--suffix-plist (node)
  "Return NODE's suffix plist, if NODE is a suffix entry.

Transient layout version 2 (Emacs 31, transient 0.10) stores a suffix
as (CLASS . PLIST).  Older transient stored (LEVEL CLASS PLIST).
Groups are vectors whose children are a plain list, so a suffix is
identified by the plist carrying `:key`, not by position alone."
  (cond
   ((and (consp node)
         (symbolp (car node))
         (not (keywordp (car node)))
         (keywordp (car-safe (cdr node)))
         (plist-get (cdr node) :key))
    (cdr node))
   ((and (consp node)
         (or (null (car node)) (integerp (car node)))
         (let ((plist (nth 2 node)))
           (and (consp plist) (keywordp (car plist))
                (plist-get plist :key))))
    (nth 2 node))))

(defun herdr-transient-test--suffixes (prefix)
  "Return (KEY . COMMAND) for every suffix of PREFIX."
  (let ((found nil))
    (letrec ((walk
              (lambda (node)
                (let ((plist (herdr-transient-test--suffix-plist node)))
                  (cond
                   (plist (push (cons (plist-get plist :key)
                                      (plist-get plist :command))
                                found))
                   ((vectorp node) (mapc walk (append node nil)))
                   ((consp node) (mapc walk node)))))))
      (funcall walk (get prefix 'transient--layout)))
    (nreverse found)))

(defun herdr-transient-test--all-suffix-plists (prefix)
  "Return the full plist of every suffix of PREFIX."
  (let ((found nil))
    (letrec ((walk
              (lambda (node)
                (let ((plist (herdr-transient-test--suffix-plist node)))
                  (cond
                   (plist (push plist found))
                   ((vectorp node) (mapc walk (append node nil)))
                   ((consp node) (mapc walk node)))))))
      (funcall walk (get prefix 'transient--layout)))
    (nreverse found)))

(ert-deftest herdr-transient-every-prefix-has-suffixes ()
  "Guards the walker itself: a broken walk would make the rest vacuous."
  (dolist (prefix herdr-transient-test--prefixes)
    (should (> (length (herdr-transient-test--suffixes prefix)) 2))))

(ert-deftest herdr-transient-no-prefix-binds-a-key-twice ()
  (dolist (prefix herdr-transient-test--prefixes)
    (let* ((keys (mapcar #'car (herdr-transient-test--suffixes prefix)))
           (duplicates (seq-filter (lambda (k) (> (seq-count (lambda (x) (equal x k))
                                                             keys)
                                                  1))
                                   (seq-uniq keys))))
      (should (equal (cons prefix nil) (cons prefix duplicates))))))

(ert-deftest herdr-transient-avoids-keys-transient-reserves ()
  "`?' and `C-h' are `transient-help'; `C-g' quits.  Do not shadow them."
  (dolist (prefix herdr-transient-test--prefixes)
    (dolist (key (mapcar #'car (herdr-transient-test--suffixes prefix)))
      (should-not (member key '("?" "C-h" "C-g" "C-q" "C-z"))))))

(ert-deftest herdr-transient-every-suffix-is-a-command ()
  (dolist (prefix herdr-transient-test--prefixes)
    (pcase-dolist (`(,key . ,command) (herdr-transient-test--suffixes prefix))
      (should (equal (list key t) (list key (and (commandp command) t)))))))

(defconst herdr-transient-test--menus
  '(herdr-transient-pane herdr-transient-agent herdr-transient-tab
    herdr-transient-workspace herdr-transient-worktree)
  "Prefixes keyed by verb.
The root prefix is deliberately excluded: its \"Go to\" column is keyed
by noun, so `p' is pane-focus and `w' is workspace-focus.  That is the
scheme, not a violation of it, and
`herdr-transient-lowercase-noun-navigates-uppercase-opens-a-menu'
asserts it separately.")

(ert-deftest herdr-transient-verbs-are-consistent-across-menus ()
  "A verb must keep its key in every menu that offers it."
  (let ((expected '(("c" . "create") ("f" . "focus") ("R" . "rename")
                    ("k" . "close\\|remove") ("r" . "read") ("l" . "list")))
        (violations nil))
    (dolist (prefix herdr-transient-test--menus)
      (pcase-dolist (`(,key . ,command) (herdr-transient-test--suffixes prefix))
        (pcase-dolist (`(,verb-key . ,verb-rx) expected)
          ;; If a command reads as this verb, it must use the verb's key.
          (when (and (string-match-p (format "herdr-\\(.*-\\)?\\(%s\\)\\'" verb-rx)
                                     (symbol-name command))
                     (not (equal key verb-key)))
            (push (format "%s: %s bound to %S, expected %S"
                          prefix command key verb-key)
                  violations)))))
    (should (equal nil violations))))

(ert-deftest herdr-transient-lowercase-noun-navigates-uppercase-opens-a-menu ()
  "The root scheme: p/a/w/t jump, P/A/W/T open the matching menu."
  (let ((root (herdr-transient-test--suffixes 'herdr-transient)))
    (pcase-dolist (`(,lower ,upper ,noun)
                   '(("p" "P" "pane") ("a" "A" "agent")
                     ("w" "W" "workspace") ("t" "T" "tab")))
      (let ((jump (cdr (assoc lower root)))
            (menu (cdr (assoc upper root))))
        (should (equal (list noun 'focus t)
                       (list noun 'focus
                             (and (string-match-p (format "herdr-%s-focus" noun)
                                                  (symbol-name jump))
                                  t))))
        (should (equal (list noun 'menu (intern (format "herdr-transient-%s" noun)))
                       (list noun 'menu menu)))))))

;;; The header must name the pane the commands will actually act on

(ert-deftest herdr-transient-header-follows-the-buffer-you-opened-it-from ()
  "Descriptions render with the transient's buffer current, so the
header has to consult the originating buffer or it will disagree with
what the commands target."
  (let* ((herdr-terminal-backend 'agent-windows)
         (mine (generate-new-buffer " *pane-b*"))
         (herdr-term--agent-buffers (list (cons "w1:pB" mine)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA")
             (panes . (((pane_id . "w1:pA") (agent . "codex"))
                       ((pane_id . "w1:pB") (agent . "claude")))))))
         (transient--original-buffer mine))
    (unwind-protect
        (with-temp-buffer            ; pretend we are rendering elsewhere
          (let ((heading (herdr-transient--target)))
            (should (string-match-p "w1:pB" heading))
            (should (string-match-p "claude" heading))))
      (kill-buffer mine))))

(ert-deftest herdr-transient-header-falls-back-to-herdr-focus ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (herdr-term--agent-buffers nil)
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA")
             (panes . (((pane_id . "w1:pA") (agent . "codex")))))))
         (transient--original-buffer nil))
    (with-temp-buffer
      (should (string-match-p "w1:pA" (herdr-transient--target))))))

;;; Tabs are TUI furniture and are filtered accordingly

(ert-deftest herdr-transient-tui-p-tracks-the-backend ()
  (let ((herdr-terminal-backend 'session))
    (should (herdr-transient-tui-p)))
  (let ((herdr-terminal-backend 'agent-windows))
    (should-not (herdr-transient-tui-p))))

(ert-deftest herdr-transient-hides-every-tab-entry-under-agent-windows ()
  "Half a tab menu was more confusing than none.  Nothing tab-shaped is
offered where nothing renders a tab."
  (let ((tab-commands '(herdr-tab-create herdr-tab-focus herdr-tab-rename
                        herdr-tab-close herdr-transient-tab)))
    (dolist (prefix '(herdr-transient herdr-transient-tab))
      (dolist (node (herdr-transient-test--all-suffix-plists prefix))
        (when (memq (plist-get node :command) tab-commands)
          (should (equal (list (plist-get node :command) 'herdr-transient-tui-p)
                         (list (plist-get node :command)
                               (plist-get node :if)))))))))

(ert-deftest herdr-transient-tab-entries-are-guarded-by-the-backend ()
  "Rename changes nothing visible without a tab bar, and focus is a
roundabout way to reach a pane."
  (let ((guarded '(herdr-tab-create herdr-tab-focus herdr-tab-rename
                   herdr-tab-close)))
    (dolist (prefix '(herdr-transient herdr-transient-tab))
      (dolist (node (herdr-transient-test--all-suffix-plists prefix))
        (when (memq (plist-get node :command) guarded)
          (should (eq 'herdr-transient-tui-p (plist-get node :if))))))))

(ert-deftest herdr-transient-workspace-entries-are-not-guarded ()
  "Workspaces are herdr's per-project unit, not layout."
  (dolist (node (herdr-transient-test--all-suffix-plists 'herdr-transient))
    (when (eq 'herdr-workspace-focus (plist-get node :command))
      (should-not (plist-get node :if)))))

(ert-deftest herdr-transient-adoption-is-offered-and-hidden-under-session ()
  "Adoption exists to make a pane attachable under `agent-windows'.
The session TUI already shows every pane, so adopting there only adds a
fake agent row to herdr's own sidebar.

Also guards a silent omission: `herdr-promote-shell' was documented as
being on the menu while never actually having been added to it."
  (let ((commands (mapcar (lambda (n) (plist-get n :command))
                          (herdr-transient-test--all-suffix-plists
                           'herdr-transient-pane))))
    (dolist (want '(herdr-adopt-shell herdr-release-shell herdr-promote-shell))
      (should (equal (list want t) (list want (and (memq want commands) t)))))))

(ert-deftest herdr-transient-every-curated-command-is-reachable ()
  "Every command in the registry should be on a menu or deliberately
listed here as reachable only through `herdr-call'.  Catches entries
that were meant to be added and silently were not."
  (let* ((prefixes '(herdr-transient herdr-transient-pane herdr-transient-agent
                     herdr-transient-tab herdr-transient-workspace
                     herdr-transient-worktree))
         (on-menu (apply #'append
                         (mapcar (lambda (p)
                                   (mapcar #'cdr
                                           (herdr-transient-test--suffixes p)))
                                 prefixes)))
         ;; Reachable only via `herdr-call', by choice.
         (deliberately-absent '(herdr-pane-send-text herdr-agent-start
                                herdr-notification-show herdr-pane-swap))
         (missing nil))
    (dolist (entry herdr-cmd-methods)
      (let ((command (car entry)))
        (unless (or (memq command on-menu)
                    (memq command deliberately-absent))
          (push command missing))))
    (should (equal nil missing))))

(ert-deftest herdr-transient-pane-basics-are-never-hidden ()
  "Splitting, reading and closing a pane mean the same under either backend."
  (dolist (node (herdr-transient-test--all-suffix-plists 'herdr-transient-pane))
    (when (memq (plist-get node :command)
                '(herdr-pane-split-right herdr-pane-read herdr-pane-close
                  herdr-pane-focus herdr-pane-run))
      (should-not (plist-get node :if))
      (should-not (plist-get node :if-not)))))

(provide 'herdr-transient-test)
;;; herdr-transient-test.el ends here
