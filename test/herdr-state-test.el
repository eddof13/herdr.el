;;; herdr-state-test.el --- Tests for the herdr state reducer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-state)

(defun herdr-state-test--pane (id &optional agent status)
  `((pane_id . ,id)
    (workspace_id . "w1")
    (tab_id . "w1:t1")
    (cwd . "/tmp")
    (agent . ,agent)
    (agent_status . ,(or status "unknown"))))

(defun herdr-state-test--seed ()
  (herdr-state-from-snapshot
   `((focused_pane_id . "w1:p1")
     (focused_tab_id . "w1:t1")
     (focused_workspace_id . "w1")
     (panes . (,(herdr-state-test--pane "w1:p1" "claude" "idle")
               ,(herdr-state-test--pane "w1:p2")))
     (tabs . (((tab_id . "w1:t1") (label . "1") (workspace_id . "w1"))))
     (workspaces . (((workspace_id . "w1") (label . "web")))))))

;;; Snapshot hydration

(ert-deftest herdr-state-from-snapshot-populates-everything ()
  (let ((state (herdr-state-test--seed)))
    (should (= 2 (length (herdr-state-panes state))))
    (should (= 1 (length (herdr-state-tabs state))))
    (should (= 1 (length (herdr-state-workspaces state))))
    (should (equal "w1:p1" (herdr-state-focused-pane-id state)))))

(ert-deftest herdr-state-agents-are-panes-with-an-agent ()
  (let ((state (herdr-state-test--seed)))
    (should (= 1 (length (herdr-state-agents state))))
    (should (equal "w1:p1"
                   (alist-get 'pane_id (car (herdr-state-agents state)))))))

;;; Reduction

(ert-deftest herdr-state-reduce-pane-created-adds-a-pane ()
  (let* ((state (herdr-state-test--seed))
         (next (herdr-state-reduce
                state "pane_created"
                `((pane . ,(herdr-state-test--pane "w1:p3"))))))
    (should (= 3 (length (herdr-state-panes next))))
    (should (herdr-state-pane next "w1:p3"))))

(ert-deftest herdr-state-reduce-is-pure ()
  "Reducing must not mutate the state it was handed."
  (let* ((state (herdr-state-test--seed))
         (_ (herdr-state-reduce state "pane_created"
                                `((pane . ,(herdr-state-test--pane "w1:p3"))))))
    (should (= 2 (length (herdr-state-panes state))))
    (should-not (herdr-state-pane state "w1:p3"))))

(ert-deftest herdr-state-reduce-pane-closed-removes-a-pane ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_closed" '((pane_id . "w1:p2")))))
    (should (= 1 (length (herdr-state-panes next))))
    (should-not (herdr-state-pane next "w1:p2"))))

(ert-deftest herdr-state-reduce-pane-exited-removes-a-pane ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_exited" '((pane_id . "w1:p1")))))
    (should-not (herdr-state-pane next "w1:p1"))))

(ert-deftest herdr-state-reduce-pane-updated-replaces-in-place ()
  "An updated pane must keep its position so pickers do not reshuffle."
  (let* ((next (herdr-state-reduce
                (herdr-state-test--seed) "pane_updated"
                `((pane . ,(herdr-state-test--pane "w1:p1" "claude" "working"))))))
    (should (= 2 (length (herdr-state-panes next))))
    (should (equal "w1:p1" (alist-get 'pane_id (car (herdr-state-panes next)))))
    (should (equal "working"
                   (alist-get 'agent_status (herdr-state-pane next "w1:p1"))))))

(ert-deftest herdr-state-reduce-dotted-agent-status-event-updates-status ()
  "Per-pane subscription events use dotted kinds and a flat payload."
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane.agent_status_changed"
               '((pane_id . "w1:p1") (workspace_id . "w1")
                 (agent_status . "blocked")))))
    (should (equal "blocked"
                   (alist-get 'agent_status (herdr-state-pane next "w1:p1"))))
    ;; Fields the event does not carry must survive untouched.
    (should (equal "claude" (alist-get 'agent (herdr-state-pane next "w1:p1"))))
    (should (equal "/tmp" (alist-get 'cwd (herdr-state-pane next "w1:p1"))))))

(ert-deftest herdr-state-reduce-agent-status-for-unknown-pane-is-a-noop ()
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane.agent_status_changed"
               '((pane_id . "w9:p9") (agent_status . "blocked")))))
    (should (= 2 (length (herdr-state-panes next))))))

(ert-deftest herdr-state-reduce-agent-detected-sets-the-agent ()
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               `((pane . ,(herdr-state-test--pane "w1:p2" "codex" "idle"))))))
    (should (= 2 (length (herdr-state-agents next))))))

(ert-deftest herdr-state-reduce-pane-focused-moves-focus ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_focused" '((pane_id . "w1:p2")))))
    (should (equal "w1:p2" (herdr-state-focused-pane-id next)))))

(ert-deftest herdr-state-reduce-workspace-and-tab-events ()
  (let* ((s (herdr-state-test--seed))
         (s (herdr-state-reduce s "workspace_created"
                                '((workspace . ((workspace_id . "w2")
                                                (label . "other"))))))
         (s (herdr-state-reduce s "tab_created"
                                '((tab . ((tab_id . "w2:t1") (label . "1")
                                          (workspace_id . "w2"))))))
         (s (herdr-state-reduce s "workspace_focused" '((workspace_id . "w2"))))
         (s (herdr-state-reduce s "tab_focused" '((tab_id . "w2:t1")))))
    (should (= 2 (length (herdr-state-workspaces s))))
    (should (= 2 (length (herdr-state-tabs s))))
    (should (equal "w2" (herdr-state-focused-workspace-id s)))
    (should (equal "w2:t1" (herdr-state-focused-tab-id s)))
    (let ((s (herdr-state-reduce s "workspace_closed" '((workspace_id . "w2")))))
      (should (= 1 (length (herdr-state-workspaces s)))))))

(defun herdr-state-test--ws-seed ()
  "State with four workspaces w1..w4 in order, for reorder tests."
  (herdr-state-from-snapshot
   `((focused_workspace_id . "w1")
     (panes . ())
     (tabs . ())
     (workspaces . (((workspace_id . "w1") (label . "one"))
                    ((workspace_id . "w2") (label . "two"))
                    ((workspace_id . "w3") (label . "three"))
                    ((workspace_id . "w4") (label . "four")))))))

(defun herdr-state-test--ws-order (state)
  "Return STATE's workspace ids in list order."
  (mapcar (lambda (w) (alist-get 'workspace_id w))
          (herdr-state-workspaces state)))

(ert-deftest herdr-state-reduce-workspace-reordered-splices-a-block ()
  "A worktree-group move relocates its block ahead of the anchor.
The payload arrives with vector fields, as `json-parse-string' decodes
arrays."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_reordered"
               `((workspace_ids . ["w3" "w4"])
                 (before_workspace_id . "w2")
                 (workspaces . [((workspace_id . "w3") (label . "three"))
                                ((workspace_id . "w4") (label . "four"))])))))
    (should (equal '("w1" "w3" "w4" "w2")
                   (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-reordered-appends-without-an-anchor ()
  "A nil `before_workspace_id' drops the block at the end."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_reordered"
               `((workspace_ids . ["w1" "w2"])
                 (before_workspace_id . nil)
                 (workspaces . [((workspace_id . "w1") (label . "one"))
                                ((workspace_id . "w2") (label . "two"))])))))
    (should (equal '("w3" "w4" "w1" "w2")
                   (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-reordered-folds-updated-info ()
  "The WorkspaceInfo the event carries refreshes fields across the move."
  (let* ((next (herdr-state-reduce
                (herdr-state-test--ws-seed) "workspace_reordered"
                `((workspace_ids . ["w3"])
                  (before_workspace_id . "w1")
                  (workspaces . [((workspace_id . "w3") (label . "renamed"))]))))
         (w3 (seq-find (lambda (w) (equal "w3" (alist-get 'workspace_id w)))
                       (herdr-state-workspaces next))))
    (should (equal '("w3" "w1" "w2" "w4") (herdr-state-test--ws-order next)))
    (should (equal "renamed" (alist-get 'label w3)))))

(ert-deftest herdr-state-reduce-workspace-reordered-is-pure ()
  "Reordering must not mutate the state it was handed."
  (let* ((state (herdr-state-test--ws-seed))
         (_ (herdr-state-reduce
             state "workspace_reordered"
             `((workspace_ids . ["w4"])
               (before_workspace_id . "w1")
               (workspaces . [((workspace_id . "w4") (label . "four"))])))))
    (should (equal '("w1" "w2" "w3" "w4") (herdr-state-test--ws-order state)))))

(ert-deftest herdr-state-reduce-ignores-layout-and-unknown-kinds ()
  (let* ((state (herdr-state-test--seed))
         (a (herdr-state-reduce state "layout_updated" '((layout . ()))))
         (b (herdr-state-reduce state "something_new" '((x . 1)))))
    (should (= 2 (length (herdr-state-panes a))))
    (should (= 2 (length (herdr-state-panes b))))
    (should (equal (herdr-state-focused-pane-id state)
                   (herdr-state-focused-pane-id b)))))

;;; Adopted shells

(ert-deftest herdr-state-attachable-includes-adopted-shells ()
  "Reconciliation attaches anything herdr will accept, shells included."
  (let ((state (herdr-state-from-snapshot
                `((panes . (((pane_id . "w1:p1") (agent . "claude"))
                            ((pane_id . "w1:p2") (agent . "shell"))
                            ((pane_id . "w1:p3") (agent . nil))))))))
    (should (equal '("w1:p1" "w1:p2")
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (herdr-state-attachable state))))))

(ert-deftest herdr-state-agents-excludes-adopted-shells ()
  "A shell is not an agent; counting it would inflate the modeline."
  (let ((state (herdr-state-from-snapshot
                `((panes . (((pane_id . "w1:p1") (agent . "claude"))
                            ((pane_id . "w1:p2") (agent . "shell"))))))))
    (should (equal '("w1:p1")
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (herdr-state-agents state))))))

(ert-deftest herdr-state-shell-pane-p-keys-off-the-configured-name ()
  (let ((herdr-shell-agent-name "adopted"))
    (should (herdr-state-shell-pane-p '((agent . "adopted"))))
    (should-not (herdr-state-shell-pane-p '((agent . "shell"))))
    (should-not (herdr-state-shell-pane-p '((agent . nil))))))

(ert-deftest herdr-state-pane-directory-prefers-cwd ()
  (should (equal "/tmp/" (herdr-state-pane-directory
                          '((cwd . "/tmp") (foreground_cwd . "/usr")))))
  (should (equal "/usr/" (herdr-state-pane-directory
                          '((foreground_cwd . "/usr")))))
  (should (null (herdr-state-pane-directory '((pane_id . "w1:p1")))))
  (should (null (herdr-state-pane-directory
                 '((cwd . "/definitely/not/here/at/all"))))))

;;; Workspace identity (WorkspaceInfo has no cwd)

(ert-deftest herdr-state-workspace-for-directory-matches-worktree-checkout ()
  "The public workspace record has no identity_cwd; worktree provenance
is how a project root maps onto a workspace."
  (let ((state (herdr-state-from-snapshot
                `((workspaces
                   . (((workspace_id . "w1") (label . "other")
                       (worktree . ((checkout_path . "/tmp/other")
                                    (repo_root . "/tmp/other"))))
                      ((workspace_id . "w2") (label . "web")
                       (worktree . ((checkout_path . "/tmp/web")
                                    (repo_root . "/tmp/web"))))))
                  (panes . ())))))
    (should (equal "w2"
                   (alist-get 'workspace_id
                              (herdr-state-workspace-for-directory
                               state "/tmp/web"))))))

(ert-deftest herdr-state-workspace-for-directory-falls-back-to-pane-cwd ()
  "A workspace that is not a worktree is identified by its panes' cwd."
  (let ((state (herdr-state-from-snapshot
                `((workspaces
                   . (((workspace_id . "w1") (label . "web"))
                      ((workspace_id . "w2") (label . "other"))))
                  (panes
                   . (((pane_id . "w1:p1") (workspace_id . "w1")
                       (cwd . "/tmp/web"))
                      ((pane_id . "w2:p1") (workspace_id . "w2")
                       (cwd . "/tmp/other"))))))))
    (should (equal "w1"
                   (alist-get 'workspace_id
                              (herdr-state-workspace-for-directory
                               state "/tmp/web/"))))))

(ert-deftest herdr-state-workspace-for-directory-is-nil-when-unknown ()
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "web"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/web"))))))))
    (should-not (herdr-state-workspace-for-directory state "/tmp/nope"))))

(provide 'herdr-state-test)
;;; herdr-state-test.el ends here
