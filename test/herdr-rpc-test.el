;;; herdr-rpc-test.el --- Tests for herdr-rpc -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-rpc)

(ert-deftest herdr-rpc-encode-empty-params-is-an-object ()
  "Empty params must serialize as {} — nil would become null and be rejected."
  (let ((json (herdr-rpc-encode "1" "ping" nil)))
    (should (string-suffix-p "\n" json))
    (should (string-match-p "\"params\":{}" json))
    (should (string-match-p "\"method\":\"ping\"" json))))

(ert-deftest herdr-rpc-encode-drops-nil-valued-params ()
  "Optional params left nil must be omitted, not sent as null."
  (let ((json (herdr-rpc-encode "1" "pane.split"
                                '((direction . "right") (cwd . nil)))))
    (should (string-match-p "\"direction\":\"right\"" json))
    (should-not (string-match-p "cwd" json))))

(ert-deftest herdr-rpc-encode-keeps-explicit-false ()
  "`:false' must survive as JSON false; only nil means absent."
  (let ((json (herdr-rpc-encode "1" "pane.split"
                                '((direction . "right") (focus . :false)))))
    (should (string-match-p "\"focus\":false" json))))

(ert-deftest herdr-rpc-call-returns-parsed-result ()
  (herdr-test-with-server
      (lambda (req)
        (cons (herdr-test-ok req '((type . "pong") (protocol . 22))) nil))
    (let ((result (herdr-rpc-call "ping")))
      (should (equal (alist-get 'type result) "pong"))
      (should (equal (alist-get 'protocol result) 22)))))

(ert-deftest herdr-rpc-call-passes-params-through ()
  (let (seen)
    (herdr-test-with-server
        (lambda (req)
          (setq seen req)
          (cons (herdr-test-ok req '((type . "ok"))) nil))
      (herdr-rpc-call "pane.close" '((pane_id . "w1:p3")))
      (should (equal (alist-get 'method seen) "pane.close"))
      (should (equal (alist-get 'pane_id (alist-get 'params seen)) "w1:p3")))))

(ert-deftest herdr-rpc-call-signals-herdr-error-with-code ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-err req "not_found" "pane not found") nil))
    (let ((err (should-error (herdr-rpc-call "pane.get" '((pane_id . "nope")))
                             :type 'herdr-error)))
      (should (equal (herdr-error-code err) "not_found"))
      (should (string-match-p "pane not found" (herdr-error-message err))))))

(ert-deftest herdr-rpc-call-without-server-signals-no-server ()
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock"))
    (let ((err (should-error (herdr-rpc-call "ping") :type 'herdr-error)))
      (should (equal (herdr-error-code err) "no_server")))))

(ert-deftest herdr-rpc-call-async-invokes-callback-with-result ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
    (let (got-result got-error done)
      (herdr-rpc-call-async "ping" nil
                            (lambda (result err)
                              (setq got-result result got-error err done t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should done)
      (should-not got-error)
      (should (equal (alist-get 'type got-result) "ok")))))

(ert-deftest herdr-rpc-call-async-reports-error-to-callback ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-err req "invalid_request" "bad") nil))
    (let (got-error done)
      (herdr-rpc-call-async "pane.split" nil
                            (lambda (_result err) (setq got-error err done t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should done)
      (should (equal (alist-get 'code got-error) "invalid_request")))))

(ert-deftest herdr-rpc-array-serializes-as-a-json-array ()
  "A list of alists is ambiguous to `json-serialize'; vectors are not."
  (let ((json (herdr-rpc-encode
               "1" "events.subscribe"
               `((subscriptions . ,(herdr-rpc-array
                                    (list '((type . "pane.created"))
                                          '((type . "pane.closed")))))))))
    (should (string-match-p
             "\"subscriptions\":\\[{\"type\":\"pane.created\"},{\"type\":\"pane.closed\"}\\]"
             json))))

(ert-deftest herdr-rpc-encode-rejects-raw-list-of-alists ()
  "Guard the mistake this replaced: a bare list of alists must not encode."
  (should-error
   (herdr-rpc-encode "1" "events.subscribe"
                     '((subscriptions . (((type . "a")) ((type . "b"))))))))

(provide 'herdr-rpc-test)
;;; herdr-rpc-test.el ends here
