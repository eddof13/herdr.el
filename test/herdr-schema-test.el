;;; herdr-schema-test.el --- Tests for herdr-schema -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-schema)

(defvar herdr-schema-test--fixture
  (expand-file-name "fixtures/schema-protocol-22.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro herdr-schema-test-with-fixture (&rest body)
  "Run BODY with the captured protocol-22 schema loaded."
  (declare (indent 0) (debug t))
  `(let ((herdr-schema--cache nil)
         (herdr-schema--cache-version nil))
     (herdr-schema-load-file herdr-schema-test--fixture)
     ,@body))

(ert-deftest herdr-schema-exposes-every-method ()
  (herdr-schema-test-with-fixture
    (let ((methods (herdr-schema-methods)))
      (should (= (length methods) 103))
      (should (member "ping" methods))
      (should (member "pane.read" methods))
      (should (member "events.subscribe" methods))
      (should (member "plugin.action.invoke" methods))
      (should (member "workspace.move_block" methods))
      (should (member "integration.list" methods)))))

(ert-deftest herdr-schema-reports-required-params ()
  (herdr-schema-test-with-fixture
    (should (equal (sort (herdr-schema-required "pane.read") #'string<)
                   '("pane_id" "source")))
    (should (equal (herdr-schema-required "ping") nil))
    (should (member "direction" (herdr-schema-required "pane.split")))
    (should (member "workspace_id" (herdr-schema-required "workspace.close")))
    (should-not (member "close_group" (herdr-schema-required "workspace.close")))))

(ert-deftest herdr-schema-lists-all-params-not-only-required ()
  (herdr-schema-test-with-fixture
    (let ((names (mapcar #'car (herdr-schema-params "pane.read"))))
      (should (member "pane_id" names))
      (should (member "lines" names))
      (should (member "strip_ansi" names))
      (should (member "format" names)))
    (let ((names (mapcar #'car (herdr-schema-params "workspace.close"))))
      (should (member "workspace_id" names))
      (should (member "close_group" names)))))

(ert-deftest herdr-schema-resolves-ref-to-enum ()
  "`source' on pane.read is a $ref; its four values must resolve."
  (herdr-schema-test-with-fixture
    (let ((choices (herdr-schema-enum "pane.read" "source")))
      (should (equal (sort choices #'string<)
                     '("detection" "recent" "recent_unwrapped" "visible"))))))

(ert-deftest herdr-schema-resolves-nested-enum-for-split-direction ()
  (herdr-schema-test-with-fixture
    (should (equal (sort (herdr-schema-enum "pane.split" "direction") #'string<)
                   '("down" "right")))))

(ert-deftest herdr-schema-reports-boolean-params ()
  (herdr-schema-test-with-fixture
    (should (eq (herdr-schema-param-type "pane.split" "focus") 'boolean))
    (should (eq (herdr-schema-param-type "pane.read" "pane_id") 'string))
    (should (eq (herdr-schema-param-type "pane.read" "lines") 'integer))
    (should (eq (herdr-schema-param-type "pane.read" "source") 'enum))))

(ert-deftest herdr-schema-unknown-method-has-no-params ()
  (herdr-schema-test-with-fixture
    (should (null (herdr-schema-params "no.such.method")))
    (should (null (herdr-schema-required "no.such.method")))))

(provide 'herdr-schema-test)
;;; herdr-schema-test.el ends here
