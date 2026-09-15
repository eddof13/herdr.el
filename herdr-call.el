;;; herdr-call.el --- Call any herdr method -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; The escape hatch.  `herdr-cmd' covers the methods worth a keybinding;
;; this reaches the other sixty-odd without anyone writing a wrapper for
;; them, by prompting from the server's own schema.
;;
;; That is why the schema is loaded at runtime instead of generating 103
;; transient prefixes: full coverage without a menu nobody can read.

;;; Code:

(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-schema)
(require 'herdr-state)
(require 'herdr-select)

(defun herdr-call--annotate (method)
  "Return an annotation for METHOD listing its required parameters."
  (let ((required (herdr-schema-required method)))
    (if required
        (format "  %s" (string-join required " "))
      "")))

(defun herdr-call--read-method ()
  "Read a method name, annotated with its required parameters."
  (let* ((methods (herdr-schema-methods))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (category . herdr-method)
                                 (annotation-function . herdr-call--annotate))
                    (complete-with-action action methods string predicate)))))
    (completing-read "herdr method: " table nil t)))

(defun herdr-call--read-value (method name)
  "Read METHOD's parameter NAME, offering pane pickers where they fit."
  (if (and (member name '("pane_id" "target"))
           (herdr-state-pane-ids (herdr-state-current)))
      ;; Ids are the one place a generic string prompt is actively worse
      ;; than what the curated commands do, so reuse the picker.
      (herdr-select-pane (format "%s: " name))
    (herdr-schema-read-param method name)))

;;;###autoload
(defun herdr-call (&optional method)
  "Call METHOD, prompting for each parameter from the server's schema.

Required parameters are always asked for.  Optional ones are asked for
only with a prefix argument; leaving a prompt empty omits it."
  (interactive)
  (let* ((method (or method (herdr-call--read-method)))
         (required (herdr-schema-required method))
         (all (mapcar #'car (herdr-schema-params method)))
         (wanted (if current-prefix-arg all required))
         (params nil))
    (dolist (name wanted)
      (let ((value (herdr-call--read-value method name)))
        (when value (push (cons (intern name) value) params))))
    (let ((result (herdr-rpc-call method (nreverse params))))
      (if (called-interactively-p 'any)
          (herdr-call--display method result)
        result))))

(defun herdr-call--display (method result)
  "Show RESULT of METHOD, briefly when small and in a buffer when not."
  (let ((printed (pp-to-string result)))
    (if (< (length printed) 200)
        (message "herdr %s -> %s" method (string-trim printed))
      (let ((buffer (get-buffer-create (format "*herdr: %s*" method))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert printed)
            (goto-char (point-min)))
          (emacs-lisp-mode)
          (view-mode 1))
        (pop-to-buffer buffer)))
    result))

(provide 'herdr-call)
;;; herdr-call.el ends here
