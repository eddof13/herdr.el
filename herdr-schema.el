;;; herdr-schema.el --- Runtime API schema for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; herdr ships a complete JSON Schema for its socket API, which this
;; package loads at runtime rather than generating code from.
;;
;; That buys two things.  `herdr-call' can offer every method the server
;; knows about, prompting for each parameter according to its declared
;; type, without anyone hand-writing 103 wrappers.  And the drift test can
;; assert that the wrappers we *did* hand-write still name methods and
;; parameters the server recognises, so a herdr upgrade surfaces as a
;; failing test instead of a runtime error.
;;
;; The schema is cached on disk and invalidated by server version.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'herdr-rpc)

(defcustom herdr-schema-cache-file
  (expand-file-name "herdr/schema.json" user-emacs-directory)
  "Where to cache the herdr API schema between sessions."
  :type 'file
  :group 'herdr)

(defvar herdr-schema--cache nil
  "Parsed schema, or nil when not yet loaded.")

(defvar herdr-schema--cache-version nil
  "herdr version the cached schema came from.")

;;; Loading

(defun herdr-schema-load-file (path)
  "Load and cache the schema stored at PATH."
  (setq herdr-schema--cache
        (with-temp-buffer
          (insert-file-contents path)
          (herdr-rpc-decode (buffer-string))))
  herdr-schema--cache)

(defun herdr-schema--fetch ()
  "Shell out to herdr for a fresh schema, caching it on disk."
  (with-temp-buffer
    (let ((status (call-process herdr-executable nil t nil
                                "api" "schema" "--json")))
      (unless (zerop status)
        (signal 'herdr-error
                (list "schema_unavailable"
                      (format "%s api schema --json exited %s"
                              herdr-executable status))))
      (make-directory (file-name-directory herdr-schema-cache-file) t)
      (write-region (point-min) (point-max) herdr-schema-cache-file nil 'quiet)
      (setq herdr-schema--cache (herdr-rpc-decode (buffer-string))))))

(defun herdr-schema--server-version ()
  "Return the running server's version string, or nil if unreachable."
  (ignore-errors (alist-get 'version (herdr-rpc-call "ping"))))

(defun herdr-schema ()
  "Return the herdr API schema, loading and caching it if needed.
The on-disk cache is reused only while the server reports the same
version it was captured from."
  (let ((version (herdr-schema--server-version)))
    (when (and herdr-schema--cache
               herdr-schema--cache-version
               version
               (not (equal version herdr-schema--cache-version)))
      (setq herdr-schema--cache nil))
    (unless herdr-schema--cache
      (if (and (file-readable-p herdr-schema-cache-file)
               (equal version herdr-schema--cache-version))
          (herdr-schema-load-file herdr-schema-cache-file)
        (herdr-schema--fetch))
      (setq herdr-schema--cache-version version)))
  herdr-schema--cache)

;;; Navigation

(defun herdr-schema--request ()
  "Return the request sub-schema."
  (alist-get 'request (alist-get 'schemas (or herdr-schema--cache
                                              (herdr-schema)))))

(defun herdr-schema--defs ()
  "Return the request schema's definitions table."
  (alist-get '$defs (herdr-schema--request)))

(defun herdr-schema-resolve (node)
  "Resolve NODE if it is a $ref or a nullable anyOf wrapper.
Returns NODE unchanged when there is nothing to resolve."
  (cond
   ((null node) nil)
   ((alist-get '$ref node)
    (let* ((ref (alist-get '$ref node))
           (name (car (last (split-string ref "/")))))
      (alist-get (intern name) (herdr-schema--defs))))
   ((alist-get 'anyOf node)
    ;; Nullable parameters are expressed as anyOf [<real thing>, null].
    (let ((real (seq-find (lambda (branch)
                            (not (equal (alist-get 'type branch) "null")))
                          (alist-get 'anyOf node))))
      (if real (herdr-schema-resolve real) node)))
   (t node)))

(defun herdr-schema--entry (method)
  "Return the oneOf entry describing METHOD, or nil."
  (seq-find (lambda (entry)
              (equal method
                     (alist-get 'const
                                (alist-get 'method
                                           (alist-get 'properties entry)))))
            (alist-get 'oneOf (herdr-schema--request))))

(defun herdr-schema-methods ()
  "Return every method name the server declares, as strings."
  (mapcar (lambda (entry)
            (alist-get 'const
                       (alist-get 'method (alist-get 'properties entry))))
          (alist-get 'oneOf (herdr-schema--request))))

(defun herdr-schema--params-def (method)
  "Return the resolved params definition for METHOD."
  (when-let* ((entry (herdr-schema--entry method))
              (params (alist-get 'params (alist-get 'properties entry))))
    (herdr-schema-resolve params)))

(defun herdr-schema-params (method)
  "Return METHOD's parameters as an alist of (NAME . SCHEMA).
NAME is a string.  SCHEMA is unresolved; use `herdr-schema-resolve'."
  (mapcar (lambda (cell) (cons (symbol-name (car cell)) (cdr cell)))
          (alist-get 'properties (herdr-schema--params-def method))))

(defun herdr-schema-required (method)
  "Return METHOD's required parameter names, as strings."
  (alist-get 'required (herdr-schema--params-def method)))

(defun herdr-schema-param (method name)
  "Return the resolved schema for METHOD's parameter NAME."
  (herdr-schema-resolve
   (cdr (assoc name (herdr-schema-params method)))))

(defun herdr-schema-enum (method name)
  "Return the permitted values for METHOD's parameter NAME, or nil."
  (alist-get 'enum (herdr-schema-param method name)))

(defun herdr-schema-param-type (method name)
  "Return a symbol describing the type of METHOD's parameter NAME.
One of `enum', `string', `boolean', `integer', `number', `object',
`array', or nil when the parameter is unknown."
  (let* ((schema (herdr-schema-param method name))
         (type (alist-get 'type schema)))
    (cond
     ((null schema) nil)
     ((alist-get 'enum schema) 'enum)
     ;; Nullable scalars arrive as ("integer" "null").
     ((consp type)
      (herdr-schema--type-symbol
       (seq-find (lambda (candidate) (not (equal candidate "null"))) type)))
     (t (herdr-schema--type-symbol type)))))

(defun herdr-schema--type-symbol (type)
  "Map JSON Schema TYPE to a symbol this package uses."
  (pcase type
    ("string" 'string)
    ("boolean" 'boolean)
    ("integer" 'integer)
    ("number" 'number)
    ("object" 'object)
    ("array" 'array)
    (_ nil)))

;;; Prompting

(defun herdr-schema-read-param (method name)
  "Prompt for METHOD's parameter NAME according to its declared type.
Returns a value ready to hand to `herdr-rpc-call', or nil to omit it."
  (let* ((required (member name (herdr-schema-required method)))
         (prompt (format "%s%s: " name (if required "" " (optional)"))))
    (pcase (herdr-schema-param-type method name)
      ('enum
       (let ((choice (completing-read prompt (herdr-schema-enum method name)
                                      nil t)))
         (if (string-empty-p choice) nil choice)))
      ('boolean
       (if (y-or-n-p (format "%s? " name)) t :false))
      ((or 'integer 'number)
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil (string-to-number raw))))
      ((or 'object 'array)
       (let ((raw (read-string (format "%s (JSON): " name))))
         (if (string-empty-p raw) nil (herdr-rpc-decode raw))))
      (_
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil raw))))))

(provide 'herdr-schema)
;;; herdr-schema.el ends here
