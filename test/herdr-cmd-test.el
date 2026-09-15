;;; herdr-cmd-test.el --- Tests for the curated commands -*- lexical-binding: t; -*-

;;; Commentary:

;; Hand-written wrappers rot as the server changes.  These check the
;; whole registry against the captured schema; the `:live' drift test
;; does the same against a running server.

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-cmd)
(require 'herdr-schema)

(defvar herdr-cmd-test--fixture
  (expand-file-name "fixtures/schema-protocol-22.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro herdr-cmd-test-with-schema (&rest body)
  (declare (indent 0) (debug t))
  `(let ((herdr-schema--cache nil) (herdr-schema--cache-version nil))
     (herdr-schema-load-file herdr-cmd-test--fixture)
     ,@body))

(ert-deftest herdr-cmd-every-command-is-defined ()
  (dolist (entry herdr-cmd-methods)
    (should (fboundp (car entry)))))

(ert-deftest herdr-cmd-every-command-is-interactive ()
  (dolist (entry herdr-cmd-methods)
    (should (commandp (car entry)))))

(ert-deftest herdr-cmd-every-method-exists-in-the-schema ()
  (herdr-cmd-test-with-schema
    (let ((known (herdr-schema-methods)))
      (dolist (entry herdr-cmd-methods)
        (should (member (nth 1 entry) known))))))

(ert-deftest herdr-cmd-every-param-exists-on-its-method ()
  "A wrapper passing an unknown parameter is rejected by the server."
  (herdr-cmd-test-with-schema
    (dolist (entry herdr-cmd-methods)
      (let* ((method (nth 1 entry))
             (declared (mapcar #'car (herdr-schema-params method))))
        (dolist (param (nthcdr 2 entry))
          (should (member param declared)))))))

(ert-deftest herdr-cmd-every-required-param-is-supplied ()
  "Omitting a required parameter fails at runtime; catch it here."
  (herdr-cmd-test-with-schema
    (dolist (entry herdr-cmd-methods)
      (let ((method (nth 1 entry))
            (passed (nthcdr 2 entry)))
        (dolist (required (herdr-schema-required method))
          (should (member required passed)))))))

(ert-deftest herdr-cmd-registry-has-no-duplicate-commands ()
  (let ((names (mapcar #'car herdr-cmd-methods)))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

(ert-deftest herdr-cmd-covers-the-curated-surface ()
  "Guard against the registry quietly shrinking."
  (should (>= (length herdr-cmd-methods) 27)))

(ert-deftest herdr-cmd-read-text-unwraps-the-read-envelope ()
  "pane.read and agent.read nest their text under a `read' object."
  (should (equal "hello"
                 (herdr-cmd-read-text
                  '((type . "pane_read")
                    (read . ((pane_id . "w1:p1") (text . "hello")))))))
  ;; Tolerate a flat shape too, rather than returning nil if it changes.
  (should (equal "flat" (herdr-cmd-read-text '((text . "flat")))))
  (should (equal "" (herdr-cmd-read-text '((type . "pane_read"))))))

(ert-deftest herdr-cmd-read-truncated-reads-the-envelope-flag ()
  "herdr flags dropped rows as `truncated' on the read envelope."
  (should (herdr-cmd-read-truncated-p
           '((type . "pane_read") (read . ((text . "x") (truncated . t))))))
  ;; Tolerate the flag arriving flat, mirroring `herdr-cmd-read-text'.
  (should (herdr-cmd-read-truncated-p '((truncated . t))))
  (should-not (herdr-cmd-read-truncated-p '((read . ((text . "x"))))))
  ;; JSON `false' decodes to nil, so an untruncated read must read as nil.
  (should-not (herdr-cmd-read-truncated-p '((read . ((truncated . nil)))))))

;;; Focus must move Emacs, not just the server

(ert-deftest herdr-pane-focus-selects-the-buffer-for-that-pane ()
  "Focusing is server-side; under `agent-windows' nothing repaints, so
Emacs has to be moved to match or the command looks like a no-op."
  (let (selected)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-pane-focus "w1:p7")
        (should (equal "w1:p7" selected))))))

(ert-deftest herdr-agent-focus-selects-a-buffer ()
  (let (selected)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane)))
              ((symbol-function 'herdr-term-select-focused) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-focus "w1:p3")
        (should (equal "w1:p3" selected))))))

(ert-deftest herdr-tab-focus-follows-to-whatever-pane-the-server-picked ()
  "Which pane a tab lands on is the server's choice, so it must be asked."
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t)))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-tab-focus "w1:t2")
        (should asked)))))

(ert-deftest herdr-workspace-focus-follows-in-emacs ()
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t)))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w2")
        (should asked)))))

;;; Panes created from Emacs must become visible

(ert-deftest herdr-cmd-created-pane-id-reads-pane-or-root-pane ()
  "pane.split answers with `pane'; tab/workspace create with `root_pane'.
Either shape names the pane just made."
  (should (equal "w1:p9"
                 (herdr-cmd--created-pane-id
                  '((type . "pane_info") (pane . ((pane_id . "w1:p9")))))))
  (should (equal "w2:p0"
                 (herdr-cmd--created-pane-id
                  '((type . "tab_created") (root_pane . ((pane_id . "w2:p0"))))))))

(ert-deftest herdr-cmd-created-pane-is-adopted-so-it-gets-a-buffer ()
  "Under `agent-windows' a new pane is a plain shell, which herdr will
not attach to.  A pane the user asked herdr.el to create should still
appear, so it is adopted."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted selected)
    ;; select-pane fails until adoption has run, then succeeds — the shell
    ;; is not attachable until it wears an agent label.
    (cl-letf (((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p)))
              ((symbol-function 'herdr-term-select-pane)
               (lambda (p) (setq selected p) adopted)))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should (equal "w1:p9" adopted))
      (should (equal "w1:p9" selected)))))

(ert-deftest herdr-cmd-created-pane-is-not-adopted-when-disabled ()
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells nil)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-cmd-created-pane-is-left-alone-under-session ()
  "The session backend shows every pane already; adopting would only
add a spurious row to herdr's own agents list."
  (let ((herdr-terminal-backend 'session)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-cmd-existing-agent-pane-is-selected-not-adopted ()
  "If the new pane already has an agent there is nothing to adopt."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) t))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-pane-split-follows-the-pane-from-the-split-response ()
  "The pane to show comes from `pane.split''s own answer, not a follow-up
`pane.current': for a paneless client the latter is the server's global
focus and can name a different pane entirely."
  (let (followed)
    (cl-letf (((symbol-function 'herdr-select-target-pane) (lambda (&rest _) "w1:p1"))
              ((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (herdr-test-with-server
          (lambda (req)
            (pcase (alist-get 'method req)
              ("pane.split"
               (cons (herdr-test-ok req '((type . "pane_info")
                                          (pane . ((pane_id . "w1:p9"))))) nil))
              ;; Would-be trap: consulting this instead is the old bug.
              ("pane.current"
               (cons (herdr-test-ok req '((type . "pane_current")
                                          (pane . ((pane_id . "w1:pWRONG"))))) nil))
              (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
        (herdr-pane-split-right)
        (should (equal "w1:p9" followed))))))

(ert-deftest herdr-tab-create-follows-its-root-pane ()
  "A new tab's pane is its `root_pane', carried in tab.create's answer."
  (let (followed)
    (cl-letf (((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (herdr-test-with-server
          (lambda (req)
            (if (equal (alist-get 'method req) "tab.create")
                (cons (herdr-test-ok req '((type . "tab_created")
                                           (root_pane . ((pane_id . "w1:p5"))))) nil)
              (cons (herdr-test-ok req '((type . "ok"))) nil)))
        (herdr-tab-create "")
        (should (equal "w1:p5" followed))))))

;;; Confirmations must not be left on screen

(ert-deftest herdr-pane-close-reports-afterwards ()
  "Closing reaps the pane's buffer, so redisplay happens while the
confirmation is still up; without a following message it sits there
looking unanswered."
  (dolist (answer '(t nil))
    (let (said)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) answer))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (herdr-test-with-server
            (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
          (herdr-pane-close "w1:p1")
          (should said)
          (should (string-match-p "w1:p1" said)))))))

(ert-deftest herdr-workspace-close-reports-afterwards ()
  (let (said)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-close "w1")
        (should (string-match-p "w1" (or said "")))))))

(ert-deftest herdr-workspace-close-retries-with-close-group-when-required ()
  "herdr 0.9 rejects closing a primary workspace that still has linked
worktrees unless `close_group' is set.  The command must offer that
rather than leaving the error on the user."
  (let (calls said)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-test-with-server
          (lambda (req)
            (let ((params (alist-get 'params req)))
              (push params calls)
              (if (eq (alist-get 'close_group params) t)
                  (cons (herdr-test-ok req '((type . "ok"))) nil)
                (cons (herdr-test-err req "workspace_group_close_required"
                                      "workspace has linked worktree workspaces")
                      nil))))
        (herdr-workspace-close "w1")
        (should (= 2 (length calls)))
        (should (equal "w1" (alist-get 'workspace_id (nth 1 calls))))
        (should-not (alist-get 'close_group (nth 1 calls)))
        (should (eq t (alist-get 'close_group (nth 0 calls))))
        (should (string-match-p "group" (or said "")))))))

(ert-deftest herdr-workspace-close-leaves-the-group-when-group-close-is-declined ()
  (let (calls said)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt)
                 (not (string-match-p "group" prompt))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-test-with-server
          (lambda (req)
            (push (alist-get 'params req) calls)
            (cons (herdr-test-err req "workspace_group_close_required"
                                  "workspace has linked worktree workspaces")
                  nil))
        (herdr-workspace-close "w1")
        (should (= 1 (length calls)))
        (should-not (alist-get 'close_group (car calls)))
        (should (string-match-p "left open" (or said "")))))))

(ert-deftest herdr-workspace-focus-offers-to-adopt-an-unattachable-pane ()
  "Landing on a plain shell would otherwise do nothing at all."
  (let (offered)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () nil))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () "w1:p4"))
              ((symbol-function 'herdr-cmd--offer-to-adopt)
               (lambda (p) (setq offered p))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w1")
        (should (equal "w1:p4" offered))))))

;;; Value-shaping wrappers: the transform is the behaviour worth locking

;; The pure passthrough commands are covered by the drift test, which
;; checks their parameters against the schema.  These few do something to
;; a value on the way through — add a newline, drop an empty field, derive
;; a default — and that transform is where a silent regression hides, so
;; it is asserted against the payload the fake server actually receives.

(defmacro herdr-cmd-test--capturing-params (var &rest body)
  "Run BODY against a fake server, binding VAR to the last request params."
  (declare (indent 1) (debug t))
  `(let (,var)
     (herdr-test-with-server
         (lambda (req)
           (setq ,var (alist-get 'params req))
           (cons (herdr-test-ok req '((type . "ok"))) nil))
       ,@body)))

(ert-deftest herdr-pane-run-sends-a-trailing-newline ()
  "There is no pane.run method: running a command is send_text plus the
newline that submits it.  Drop the newline and the command sits at the
prompt unentered."
  (herdr-cmd-test--capturing-params params
    (herdr-pane-run "make test" "w1:p1")
    (should (equal "make test\n" (alist-get 'text params)))))

(ert-deftest herdr-pane-send-text-sends-verbatim ()
  "The counterpart to `herdr-pane-run': text goes as typed, with no
newline, so it can fill a prompt without submitting it."
  (herdr-cmd-test--capturing-params params
    (herdr-pane-send-text "make test" "w1:p1")
    (should (equal "make test" (alist-get 'text params)))))

(ert-deftest herdr-worktree-create-omits-an-empty-base ()
  "An empty base means \"off the current ref\"; a blank string is a
different request, and nil is dropped from the payload entirely."
  (dolist (case '(("" . nil) ("main" . "main")))
    (herdr-cmd-test--capturing-params params
      (herdr-worktree-create "feature" (car case))
      (should (equal "feature" (alist-get 'branch params)))
      (should (equal (cdr case) (alist-get 'base params))))))

(ert-deftest herdr-workspace-create-defaults-the-label-to-the-directory ()
  "An unnamed workspace should still read as something, so it borrows the
directory's own name."
  (let ((herdr-terminal-backend 'session))
    (herdr-cmd-test--capturing-params params
      (herdr-workspace-create "/tmp/herdr-example/" nil)
      (should (equal "herdr-example" (alist-get 'label params))))))

(ert-deftest herdr-notification-show-omits-an-empty-body ()
  "A blank body is absence, not an empty line; only title and sound go."
  (herdr-cmd-test--capturing-params params
    (herdr-notification-show "Done" "")
    (should (equal "Done" (alist-get 'title params)))
    (should (null (alist-get 'body params)))
    (should (equal "none" (alist-get 'sound params)))))

;;; Promoting an adopted shell branches on what is detected

(ert-deftest herdr-promote-shell-reports-the-detected-agent ()
  "Once a real agent is running in an adopted shell, relabel the pane
with it so it stops reading as a bare shell."
  (let (resynced said)
    (cl-letf (((symbol-function 'herdr-state-detected-agent)
               (lambda (_) "claude"))
              ((symbol-function 'herdr-state-resync)
               (lambda (&rest _) (setq resynced t)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-cmd-test--capturing-params params
        (herdr-promote-shell "w1:p1")
        (should (equal "claude" (alist-get 'agent params)))
        (should resynced)
        (should (string-match-p "promoted" (or said "")))))))

(ert-deftest herdr-promote-shell-does-nothing-without-a-detected-agent ()
  (let (called said)
    (cl-letf (((symbol-function 'herdr-state-detected-agent) (lambda (_) nil))
              ((symbol-function 'herdr-rpc-call)
               (lambda (&rest _) (setq called t)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-promote-shell "w1:p1")
      (should-not called)
      (should (string-match-p "no agent detected" (or said ""))))))

(ert-deftest herdr-promote-shell-leaves-a-plain-shell-alone ()
  "A pane still wearing only the adopted-shell label has nothing to be
promoted to, so it must not report anything."
  (let ((herdr-shell-agent-name "herdr-shell")
        called said)
    (cl-letf (((symbol-function 'herdr-state-detected-agent)
               (lambda (_) "herdr-shell"))
              ((symbol-function 'herdr-rpc-call)
               (lambda (&rest _) (setq called t)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-promote-shell "w1:p1")
      (should-not called)
      (should (string-match-p "still just a shell" (or said ""))))))

;;; Starting an agent must surface it

(ert-deftest herdr-agent-start-focuses-and-shows-the-new-agent ()
  "Starting an agent that goes nowhere on screen reads as a no-op: the
pane it runs in must be focused server-side and its buffer selected, or
you only learn it worked on the next reload."
  (let (selected focused)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane) t)))
      (herdr-test-with-server
          (lambda (req)
            (when (equal (alist-get 'method req) "pane.focus")
              (setq focused (alist-get 'pane_id (alist-get 'params req))))
            (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-start "web" "claude" "w1:p1")
        (should (equal "w1:p1" selected))
        (should (equal "w1:p1" focused))))))

(ert-deftest herdr-agent-start-waits-for-a-buffer-that-is-not-ready ()
  "Under `agent-windows' the buffer is built off the event stream, so it
may not exist the instant `agent.start' returns.  When select cannot
show it yet the command schedules a retry rather than giving up."
  (let (deferred)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-cmd--select-pane-when-ready)
               (lambda (pane) (setq deferred pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-start "web" "claude" "w1:p1")
        (should (equal "w1:p1" deferred))))))

(ert-deftest herdr-agent-start-create-new-splits-then-starts-on-the-new-pane ()
  "Picking create-new splits the current pane and starts the agent in the
pane the split returns, then shows it — no detour through a manual split."
  (let (split-target started-in selected)
    (cl-letf (((symbol-function 'herdr-select-available-shell)
               (lambda (&rest _) :create-new))
              ((symbol-function 'herdr-select-current-target)
               (lambda (&rest _) "w1:p1"))
              ((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane) t)))
      (herdr-test-with-server
          (lambda (req)
            (let ((method (alist-get 'method req))
                  (params (alist-get 'params req)))
              (cond
               ((equal method "pane.split")
                (setq split-target (alist-get 'target_pane_id params))
                (cons (herdr-test-ok req '((type . "pane_info")
                                           (pane . ((pane_id . "w1:p9")))))
                      nil))
               ((equal method "agent.start")
                (setq started-in (alist-get 'pane_id params))
                (cons (herdr-test-ok req '((type . "ok"))) nil))
               (t (cons (herdr-test-ok req '((type . "ok"))) nil)))))
        (should (equal "w1:p9" (herdr-agent-start "web" "claude")))
        (should (equal "w1:p1" split-target))
        (should (equal "w1:p9" started-in))
        (should (equal "w1:p9" selected))))))

(provide 'herdr-cmd-test)
;;; herdr-cmd-test.el ends here
