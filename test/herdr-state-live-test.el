;;; herdr-state-live-test.el --- Tests for herdr event stream handling -*- lexical-binding: t; -*-

;;; Commentary:

;; NDJSON framing is where a stream client usually breaks: TCP does not
;; respect message boundaries, so a chunk may hold several events, half
;; an event, or both.  These drive the filter directly with hostile
;; chunking.

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-state)

(defun herdr-state-live-test--proc ()
  "Return a throwaway process that can carry filter state."
  (make-pipe-process :name "herdr-test-pipe" :noquery t))

(defmacro herdr-state-live-test-with-capture (&rest body)
  "Run BODY capturing dispatched events into the list `events'."
  (declare (indent 0) (debug t))
  `(let* ((events nil)
          (herdr-state--current (herdr-state-empty))
          (herdr-state-change-hook
           (list (lambda (kind data) (push (cons kind data) events))))
          (proc (herdr-state-live-test--proc)))
     (unwind-protect (progn ,@body (setq events (nreverse events)))
       (delete-process proc))))

(ert-deftest herdr-state-filter-ignores-the-subscription-ack ()
  "The ack is a response, not an event; reducing against it is meaningless."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc "{\"id\":\"1\",\"result\":{\"type\":\"subscription_started\"}}\n"))))
    (should (null events))))

(ert-deftest herdr-state-filter-splits-two-events-in-one-chunk ()
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc
                   (concat
                    "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p1\"}}\n"
                    "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p2\"}}\n")))))
    (should (= 2 (length events)))
    (should (equal "w1:p1" (alist-get 'pane_id (cdr (nth 0 events)))))
    (should (equal "w1:p2" (alist-get 'pane_id (cdr (nth 1 events)))))))

(ert-deftest herdr-state-filter-buffers-a-partial-line ()
  "A chunk that ends mid-event must produce nothing until its newline."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter proc "{\"event\":\"pane_focu")
                  (should (null events))
                  (herdr-state--filter
                   proc "sed\",\"data\":{\"pane_id\":\"w1:p9\"}}\n"))))
    (should (= 1 (length events)))
    (should (equal "w1:p9" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-handles-a-split-across-three-chunks ()
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter proc "{\"event\":\"pane_f")
                  (herdr-state--filter proc "ocused\",\"data\":{\"pane")
                  (herdr-state--filter proc "_id\":\"w1:p3\"}}\n"))))
    (should (= 1 (length events)))
    (should (equal "w1:p3" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-survives-a-malformed-line ()
  "One bad line must not take down the stream."
  (let ((events (herdr-state-live-test-with-capture
                  (herdr-state--filter
                   proc (concat "not json at all\n"
                                "{\"event\":\"pane_focused\",\"data\":{\"pane_id\":\"w1:p4\"}}\n")))))
    (should (= 1 (length events)))
    (should (equal "w1:p4" (alist-get 'pane_id (cdr (car events)))))))

(ert-deftest herdr-state-filter-updates-the-cache-as-it-dispatches ()
  (herdr-state-live-test-with-capture
    (herdr-state--filter
     proc (concat "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                  "{\"pane_id\":\"w1:p7\",\"agent\":\"codex\","
                  "\"agent_status\":\"working\"}}}\n"))
    (should (herdr-state-pane herdr-state--current "w1:p7"))
    (should (= 1 (length (herdr-state-agents herdr-state--current))))))

(ert-deftest herdr-state-pane-subscriptions-cover-every-pane ()
  "Connection B must name every pane, since these subscriptions are per-pane."
  (let ((herdr-state--current
         (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1")) ((pane_id . "w1:p2"))))))))
    (let ((subs (herdr-state--pane-subscriptions)))
      ;; A vector, so it serializes as a JSON array rather than an object.
      (should (vectorp subs))
      (should (= 2 (length subs)))
      (should (equal "pane.agent_status_changed" (alist-get 'type (aref subs 0))))
      (should (equal '("w1:p1" "w1:p2")
                     (mapcar (lambda (s) (alist-get 'pane_id s)) subs))))))

(ert-deftest herdr-state-start-signals-when-no-server ()
  "Starting without a server must fail cleanly and leave nothing running."
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock"))
    (herdr-state-stop)
    (should-error (herdr-state-start) :type 'herdr-error)
    (should-not (herdr-state-running-p))))

(ert-deftest herdr-state-start-hydrates-from-a-fake-server ()
  (herdr-test-with-server
      (lambda (req)
        (if (equal (alist-get 'method req) "session.snapshot")
            (cons (herdr-test-ok
                   req '((snapshot . ((focused_pane_id . "w1:p1")
                                      (panes . [((pane_id . "w1:p1")
                                                 (agent . "claude")
                                                 (agent_status . "idle"))])))))
                  nil)
          ;; events.subscribe: ack and hold the connection open.
          (cons (herdr-test-ok req '((type . "subscription_started"))) t)))
    (unwind-protect
        (progn
          (herdr-state-start)
          (should (herdr-state-running-p))
          (should (equal "w1:p1"
                         (herdr-state-focused-pane-id (herdr-state-current))))
          (should (= 1 (length (herdr-state-agents (herdr-state-current))))))
      (herdr-state-stop))))

(ert-deftest herdr-state-start-subscribes-before-taking-a-snapshot ()
  "Lifecycle subscriptions no longer replay, so the stream must be live
before the snapshot or events in the gap are lost."
  (let (order)
    (herdr-test-with-server
        (lambda (req)
          (push (alist-get 'method req) order)
          (if (equal (alist-get 'method req) "session.snapshot")
              (cons (herdr-test-ok
                     req '((snapshot . ((focused_pane_id . "w1:p1")
                                        (panes . [])))))
                    nil)
            (cons (herdr-test-ok req '((type . "subscription_started"))) t)))
      (unwind-protect
          (progn
            (herdr-state-start)
            (let ((methods (nreverse order)))
              (should (equal "events.subscribe" (car methods)))
              (should (member "session.snapshot" methods))
              (should (< (seq-position methods "events.subscribe")
                         (seq-position methods "session.snapshot")))))
        (herdr-state-stop)))))

(ert-deftest herdr-state-start-applies-events-buffered-during-snapshot ()
  "Events that arrive after subscribe and before the snapshot is
installed must still land in the cache, applied after the snapshot."
  (herdr-test-with-server
      (lambda (req)
        (pcase (alist-get 'method req)
          ("session.snapshot"
           (cons (herdr-test-ok
                  req '((snapshot . ((focused_pane_id . "w1:p1")
                                     (panes . [((pane_id . "w1:p1"))])))))
                 nil))
          ("events.subscribe"
           (cons (concat
                  (herdr-test-ok req '((type . "subscription_started")))
                  "{\"event\":\"pane_created\",\"data\":{\"pane\":{\"pane_id\":\"w1:p2\",\"agent\":\"codex\"}}}\n")
                 t))
          (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
    (unwind-protect
        (progn
          (herdr-state-start)
          (should (herdr-state-pane (herdr-state-current) "w1:p1"))
          (should (herdr-state-pane (herdr-state-current) "w1:p2"))
          (should (equal "codex"
                         (alist-get 'agent
                                    (herdr-state-pane (herdr-state-current)
                                                      "w1:p2")))))
      (herdr-state-stop))))

(ert-deftest herdr-state-bootstrapping-suppresses-the-change-hook ()
  "Events buffered while the snapshot is in flight must fold into the
cache without notifying listeners for each one."
  (let* ((events nil)
         (herdr-state--current (herdr-state-empty))
         (herdr-state--bootstrapping 'buffer)
         (herdr-state--event-buffer nil)
         (herdr-state-change-hook
          (list (lambda (kind data) (push (cons kind data) events))))
         (proc (herdr-state-live-test--proc)))
    (unwind-protect
        (progn
          (herdr-state--filter
           proc (concat "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p1\"}}}\n"
                        "{\"event\":\"pane_created\",\"data\":{\"pane\":"
                        "{\"pane_id\":\"w1:p2\"}}}\n"))
          (should (null events))
          (should-not (herdr-state-pane herdr-state--current "w1:p1"))
          (herdr-state--apply-buffered-events)
          (should (= 2 (length (herdr-state-panes herdr-state--current))))
          (should (null events)))
      (delete-process proc))))

(ert-deftest herdr-state-not-bootstrapping-notifies-per-event ()
  (let* ((events nil)
         (herdr-state--current (herdr-state-empty))
         (herdr-state--bootstrapping nil)
         (herdr-state-change-hook
          (list (lambda (kind data) (push (cons kind data) events))))
         (proc (herdr-state-live-test--proc)))
    (unwind-protect
        (progn
          (herdr-state--filter
           proc "{\"event\":\"pane_created\",\"data\":{\"pane\":{\"pane_id\":\"w1:p1\"}}}\n")
          (should (= 1 (length events))))
      (delete-process proc))))

;;; Reconciling the pane set against the server

(defun herdr-state-live-test--pane-list-server (panes)
  "Return a responder answering `pane.list' with PANES."
  (lambda (req)
    (cons (herdr-test-ok req `((type . "pane_list") (panes . ,panes))) nil)))

(ert-deftest herdr-state-reconcile-drops-panes-the-server-no-longer-has ()
  "A missed `pane_closed' (disconnect gap, or a burst the cache did not
fold) leaves panes in every picker that cannot be navigated to.
`pane.list' is the authoritative set."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))
                        ((pane_id . "w1:ghost1"))
                        ((pane_id . "w1:ghost2"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal '("w1:p1") (herdr-state-pane-ids herdr-state--current))))))

(ert-deftest herdr-state-reconcile-adds-panes-the-cache-missed ()
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))
        ((pane_id . "w1:p2") (cwd . "/tmp") (agent . "claude"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal '("w1:p1" "w1:p2")
                     (herdr-state-pane-ids herdr-state--current)))
      (should (= 1 (length (herdr-state-agents herdr-state--current)))))))

(ert-deftest herdr-state-reconcile-picks-up-directory-changes ()
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/usr/local"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (should (equal "/usr/local"
                     (alist-get 'cwd (herdr-state-pane herdr-state--current
                                                       "w1:p1")))))))

(ert-deftest herdr-state-reconcile-reports-no-change-when-in-sync ()
  "The poll runs every few seconds; it must not fire the change hook
for nothing."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
      (should-not (herdr-state-reconcile-panes)))))

(ert-deftest herdr-state-reconcile-leaves-the-cache-alone-when-unreachable ()
  "A failed poll must not empty the cache."
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock")
        (herdr-state--current
         (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1"))))))))
    (should-not (herdr-state-reconcile-panes))
    (should (equal '("w1:p1") (herdr-state-pane-ids herdr-state--current)))))

;;; Promoting an adopted shell that has since started an agent

(ert-deftest herdr-state-detected-agent-reads-the-detector-not-the-label ()
  "`agent.explain' reports what detection concluded, which stays visible
even while another source holds the pane's agent label."
  (herdr-test-with-server
      (lambda (req)
        (cons (herdr-test-ok req '((type . "agent_explain")
                                   (explain . ((agent . "claude")))))
              nil))
    (should (equal "claude" (herdr-state-detected-agent "w1:p1")))))

(ert-deftest herdr-state-detected-agent-is-nil-when-unavailable ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-err req "agent_not_found" "nope") nil))
    (should-not (herdr-state-detected-agent "w1:p1"))))

(ert-deftest herdr-state-promotes-an-adopted-shell-running-an-agent ()
  "Adoption suppresses detection, so a shell that later starts Claude
would stay labelled `shell' forever without this."
  (let (reported)
    (herdr-test-with-server
        (lambda (req)
          (pcase (alist-get 'method req)
            ("agent.explain"
             (cons (herdr-test-ok req '((explain . ((agent . "claude"))))) nil))
            ("pane.report_agent"
             (setq reported (alist-get 'params req))
             (cons (herdr-test-ok req '((type . "ok"))) nil))
            (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
      (let ((herdr-state--current
             (herdr-state-from-snapshot
              '((panes . (((pane_id . "w1:p1") (agent . "shell"))))))))
        (should (herdr-state-promote-shell-panes))
        (should (equal "claude" (alist-get 'agent reported)))
        (should (equal "w1:p1" (alist-get 'pane_id reported)))))))

(ert-deftest herdr-state-does-not-promote-a-shell-with-no-agent ()
  (let (reported)
    (herdr-test-with-server
        (lambda (req)
          (pcase (alist-get 'method req)
            ("agent.explain"
             (cons (herdr-test-err req "agent_not_found" "none") nil))
            ("pane.report_agent"
             (setq reported t)
             (cons (herdr-test-ok req '((type . "ok"))) nil))
            (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
      (let ((herdr-state--current
             (herdr-state-from-snapshot
              '((panes . (((pane_id . "w1:p1") (agent . "shell"))))))))
        (should-not (herdr-state-promote-shell-panes))
        (should-not reported)))))

(ert-deftest herdr-state-does-not-touch-real-agents ()
  "Only adopted shells are candidates; a real agent must be left alone."
  (let (reported)
    (herdr-test-with-server
        (lambda (req)
          (when (equal (alist-get 'method req) "pane.report_agent")
            (setq reported t))
          (cons (herdr-test-ok req '((type . "ok"))) nil))
      (let ((herdr-state--current
             (herdr-state-from-snapshot
              '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
        (should-not (herdr-state-promote-shell-panes))
        (should-not reported)))))

(ert-deftest herdr-state-reconcile-refreshes-a-changed-agent-label ()
  "A shell promoted to a real agent must not keep its old label.
Refreshing only cwd left the cache reporting `shell' indefinitely."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (agent . "claude") (agent_status . "working")
         (cwd . "/tmp"))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (agent . "shell")
                         (agent_status . "idle") (cwd . "/tmp"))))))))
      (should (herdr-state-reconcile-panes))
      (let ((pane (herdr-state-pane herdr-state--current "w1:p1")))
        (should (equal "claude" (alist-get 'agent pane)))
        (should (equal "working" (alist-get 'agent_status pane))))
      (should (= 1 (length (herdr-state-agents herdr-state--current)))))))

(ert-deftest herdr-state-reconcile-ignores-volatile-fields ()
  "Revision and scroll churn constantly; reacting to them would make
every poll report a change and refresh every consumer."
  (herdr-test-with-server
      (herdr-state-live-test--pane-list-server
       [((pane_id . "w1:p1") (cwd . "/tmp") (revision . 99)
         (scroll . ((offset_from_bottom . 5))))])
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1") (cwd . "/tmp") (revision . 1))))))))
      (should-not (herdr-state-reconcile-panes)))))

(provide 'herdr-state-live-test)
;;; herdr-state-live-test.el ends here
