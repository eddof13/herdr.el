;;; herdr-drift-test.el --- Live conformance tests -*- lexical-binding: t; -*-

;;; Commentary:

;; These need a running herdr server and are tagged `:live', so `make
;; test' skips them and `make test-live' runs them.
;;
;; The point is drift.  Every curated command is hand-written against a
;; method signature, and herdr is at 0.9.x — signatures will move.  When
;; they do, this fails with the offending command named, instead of a
;; user finding out through a not_found at the wrong moment.
;;
;; The round-trip test also asserts the session is left exactly as it
;; was found, so running the suite is not destructive.

;;; Code:

(require 'ert)
(require 'herdr)
(require 'herdr-rpc)
(require 'herdr-schema)
(require 'herdr-cmd)
(require 'herdr-state)

(defun herdr-drift-test--server-p ()
  "Return non-nil when a herdr server is reachable."
  (condition-case nil (progn (herdr-rpc-call "ping") t) (herdr-error nil)))

(defmacro herdr-drift-test-with-server (&rest body)
  "Run BODY, skipping the test when no herdr server is running."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (herdr-drift-test--server-p))
     (let ((herdr-schema--cache nil) (herdr-schema--cache-version nil))
       (herdr-schema)
       ,@body)))

(ert-deftest herdr-drift-protocol-matches ()
  :tags '(:live)
  (skip-unless (herdr-drift-test--server-p))
  (let ((protocol (alist-get 'protocol (herdr-rpc-call "ping"))))
    (should (equal protocol herdr-protocol-version))))

(ert-deftest herdr-drift-every-curated-method-still-exists ()
  :tags '(:live)
  (herdr-drift-test-with-server
    (let ((known (herdr-schema-methods))
          (missing nil))
      (dolist (entry herdr-cmd-methods)
        (unless (member (nth 1 entry) known)
          (push (format "%s -> %s" (nth 0 entry) (nth 1 entry)) missing)))
      (should (equal nil missing)))))

(ert-deftest herdr-drift-every-curated-param-still-exists ()
  :tags '(:live)
  (herdr-drift-test-with-server
    (let ((bad nil))
      (dolist (entry herdr-cmd-methods)
        (let* ((method (nth 1 entry))
               (declared (mapcar #'car (herdr-schema-params method))))
          (dolist (param (nthcdr 2 entry))
            (unless (member param declared)
              (push (format "%s: %s has no %s" (nth 0 entry) method param) bad)))))
      (should (equal nil bad)))))

(ert-deftest herdr-drift-required-params-are-all-supplied ()
  :tags '(:live)
  (herdr-drift-test-with-server
    (let ((bad nil))
      (dolist (entry herdr-cmd-methods)
        (let ((method (nth 1 entry))
              (passed (nthcdr 2 entry)))
          (dolist (required (herdr-schema-required method))
            (unless (member required passed)
              (push (format "%s omits required %s of %s"
                            (nth 0 entry) required method)
                    bad)))))
      (should (equal nil bad)))))

(ert-deftest herdr-drift-round-trip-leaves-the-session-unchanged ()
  "Split, rename, run, read back, close — and restore what we found."
  :tags '(:live)
  (skip-unless (herdr-drift-test--server-p))
  (let* ((before (alist-get 'panes
                            (alist-get 'snapshot
                                       (herdr-rpc-call "session.snapshot"))))
         (pane (alist-get 'pane_id
                          (alist-get 'pane
                                     (herdr-rpc-call
                                      "pane.split"
                                      '((direction . "right")))))))
    (unwind-protect
        (progn
          (herdr-rpc-call "pane.rename" `((pane_id . ,pane)
                                          (label . "herdr-el-drift")))
          (herdr-rpc-call "pane.send_text"
                          `((pane_id . ,pane)
                            (text . "echo HERDR_DRIFT_OK\n")))
          (sleep-for 2)
          (let ((text (herdr-cmd-read-text
                       (herdr-rpc-call "pane.read"
                                       `((pane_id . ,pane)
                                         (source . "recent_unwrapped")
                                         (strip_ansi . t))))))
            (should (string-match-p "HERDR_DRIFT_OK" text))))
      (herdr-rpc-call "pane.close" `((pane_id . ,pane))))
    (sleep-for 1)
    (let ((after (alist-get 'panes
                            (alist-get 'snapshot
                                       (herdr-rpc-call "session.snapshot")))))
      (should (equal (mapcar (lambda (p) (alist-get 'pane_id p)) before)
                     (mapcar (lambda (p) (alist-get 'pane_id p)) after))))))

(ert-deftest herdr-drift-event-stream-delivers ()
  "A change made over RPC must reach the cache through the event stream."
  :tags '(:live)
  (skip-unless (herdr-drift-test--server-p))
  (herdr-state-stop)
  (unwind-protect
      (progn
        (herdr-state-start)
        (let ((deadline (+ (float-time) 6)))
          (while (< (float-time) deadline) (accept-process-output nil 0.1)))
        (let ((pane (alist-get 'pane_id
                               (alist-get 'pane
                                          (herdr-rpc-call
                                           "pane.split"
                                           '((direction . "right")))))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (not (herdr-state-pane (herdr-state-current) pane)))
              (accept-process-output nil 0.1)))
          (should (herdr-state-pane (herdr-state-current) pane))
          (herdr-rpc-call "pane.close" `((pane_id . ,pane)))
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (herdr-state-pane (herdr-state-current) pane))
              (accept-process-output nil 0.1)))
          (should-not (herdr-state-pane (herdr-state-current) pane))))
    (herdr-state-stop)))

(provide 'herdr-drift-test)
;;; herdr-drift-test.el ends here
