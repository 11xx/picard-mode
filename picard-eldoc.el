;;; picard-eldoc.el --- Eldoc support for Picard Tagger Script  -*- lexical-binding: t -*-

;; Author: 11xx
;; Version: 2026.04.08
;; Package-Requires: ((emacs "27.1") (picard-data "0.1.0"))
;; Keywords: languages, tools, picard, musicbrainz, eldoc
;; URL: https://github.com/example/picard-mode

;;; Commentary:

;; This file provides Eldoc integration for Picard Tagger Script buffers.
;;
;; Eldoc (built into Emacs) displays contextual documentation in the echo
;; area as the cursor moves.  Support is provided by registering a function
;; in `eldoc-documentation-functions' (Emacs 28+) or by setting the older
;; `eldoc-documentation-function' variable.  The registered function is
;; called with an optional callback argument CB; when CB is non-nil the
;; result must be passed to it; when CB is nil the result is returned
;; directly.  This file follows the newer multi-source protocol introduced
;; in Emacs 28 (see `(info "(emacs) Eldoc")').
;;
;; Context detection
;; -----------------
;; Two contexts are recognised:
;;
;;   Function call — point is inside `$funcname(...)'.
;;     Detected by searching backward for `$name(' and forward for the
;;     matching `)'.  The current argument index is determined by counting
;;     unbalanced commas between the opening paren and point.
;;
;;   Variable reference — point is inside `%varname%'.
;;     Detected by checking whether the count of `%' characters between
;;     line start and point is odd (meaning point is inside a variable).
;;
;; Signature formatting
;; --------------------
;; Functions:
;;   $if(condition, then[, else]) — conditional: If condition is non-empty…
;;
;; Variables:
;;   %artist% — basic-tag: The primary artist of the recording.
;;
;; Argument names are synthetic — they are generated from the parameter
;; index and the function's category when no named parameter list is
;; available.
;;
;; Tree-sitter path
;; ----------------
;; When a tree-sitter parser is active, `treesit-node-at' locates the
;; node at point.  The function walks up the tree to find the enclosing
;; `function_call' or `variable' node and reads field children directly
;; from the syntax tree.
;;
;; Setup
;; -----
;;   (add-hook \\='picard-mode-hook #\\='picard-eldoc-setup)

;;; Code:

(require 'cl-lib)
(require 'picard-data)

;; Tree-sitter functions are called only when `treesit' is available at
;; runtime.  The `declare-function' forms below silence byte-compiler
;; warnings without requiring the `treesit' feature unconditionally.
(declare-function treesit-parser-list      "treesit" (&optional buffer language))
(declare-function treesit-node-at          "treesit" (pos &optional parser-or-lang named))
(declare-function treesit-node-type        "treesit" (node))
(declare-function treesit-node-parent      "treesit" (node))
(declare-function treesit-node-child-by-field-name "treesit" (node field-name))
(declare-function treesit-node-text        "treesit" (node &optional with-properties))
(declare-function treesit-node-start       "treesit" (node))
(declare-function treesit-node-end         "treesit" (node))
(declare-function treesit-node-children    "treesit" (node &optional named))

;;;; Signature generation

(defconst picard--generic-arg-names
  '("arg1" "arg2" "arg3" "arg4" "arg5" "arg6" "arg7" "arg8")
  "Generic argument placeholder names used when building function signatures.
When the database does not supply named parameters, positional names from
this list are used.")

(defun picard-eldoc--make-signature (func-name info &optional current-arg)
  "Return a formatted signature string for FUNC-NAME.

INFO is the plist from `picard-function-info'.  CURRENT-ARG, when
non-nil, is the zero-based index of the argument at point; that argument
will be highlighted with the `eldoc-highlight-function-argument' face.

The format is:
  $funcname(req1, req2[, opt1]) — category: docstring"
  (let* ((min-args (plist-get info :min-args))
         (max-args (plist-get info :max-args))
         (category (plist-get info :category))
         (doc      (plist-get info :doc))
         (args     '()))
    ;; Build argument list: required args first, then optional in brackets.
    (cond
     ;; No arguments at all.
     ((and (= min-args 0) (= max-args 0))
      ;; args stays empty.
      nil)
     ;; All required, fixed arity.
     ((and (> min-args 0) (= min-args max-args))
      (dotimes (i min-args)
        (let ((label (picard-eldoc--arg-label func-name i min-args max-args)))
          (push (if (and current-arg (= i current-arg))
                    (propertize label 'face 'eldoc-highlight-function-argument)
                  label)
                args)))
      (setq args (nreverse args)))
     ;; Mix of required and optional args (max-args > min-args, not variadic).
     ((and (> max-args min-args) (not (= max-args -1)))
      (dotimes (i max-args)
        (let* ((label (picard-eldoc--arg-label func-name i min-args max-args))
               (face-label (if (and current-arg (= i current-arg))
                               (propertize label 'face
                                           'eldoc-highlight-function-argument)
                             label))
               (optional-p (>= i min-args)))
          (push (if optional-p
                    (concat "[" face-label "]")
                  face-label)
                args)))
      (setq args (nreverse args)))
     ;; Some required args + variadic.
     ((= max-args -1)
      ;; Required args.
      (dotimes (i min-args)
        (let ((label (picard-eldoc--arg-label func-name i min-args max-args)))
          (push (if (and current-arg (= i current-arg))
                    (propertize label 'face 'eldoc-highlight-function-argument)
                  label)
                args)))
      ;; Variadic rest.
      (let ((rest-label "..."))
        (push (if (and current-arg (>= current-arg min-args))
                  (propertize rest-label 'face 'eldoc-highlight-function-argument)
                rest-label)
              args))
      (setq args (nreverse args)))
     ;; Pure variadic (min-args = 0, max-args = -1).
     ((= min-args 0)
      (setq args (list "[...]"))))
    (format "%s(%s) — %s: %s"
            func-name
            (mapconcat #'identity args ", ")
            category
            doc)))

(defun picard-eldoc--arg-label (func-name index &optional _min-args _max-args)
  "Return a human-readable argument name for FUNC-NAME at zero-based INDEX.

The optional _MIN-ARGS and _MAX-ARGS arguments are accepted for
call-site symmetry but are not used; bracket wrapping of optional
arguments is performed by the caller.

A small set of well-known functions have hand-tuned argument names.
All others fall back to generic positional names from
`picard--generic-arg-names'."
  (let ((named
         (cdr (assoc func-name
                     '(("$if"       . ("condition" "then" "else"))
                       ("$foreach"  . ("variable"  "loop-code" "separator"))
                       ("$map"      . ("variable"  "loop-code" "separator"))
                       ("$while"    . ("condition" "loop-code"))
                       ("$set"      . ("name"      "value"))
                       ("$get"      . ("name"))
                       ("$unset"    . ("name"))
                       ("$delete"   . ("name"))
                       ("$copy"     . ("old"       "new"))
                       ("$replace"  . ("text"      "old"   "new"))
                       ("$rreplace" . ("text"      "old"   "new"))
                       ("$rsearch"  . ("text"      "pattern" "group"))
                       ("$left"     . ("text"      "length"))
                       ("$right"    . ("text"      "length"))
                       ("$substr"   . ("text"      "start" "end"))
                       ("$pad"      . ("text"      "length" "char"))
                       ("$num"      . ("number"    "length"))
                       ("$truncate" . ("text"      "length"))
                       ("$find"     . ("haystack"  "needle"))
                       ("$in"       . ("text"      "needle"))
                       ("$startswith" . ("text"    "prefix"))
                       ("$endswith"   . ("text"    "suffix"))
                       ("$eq"       . ("x"         "y"))
                       ("$ne"       . ("x"         "y"))
                       ("$lt"       . ("x"         "y"   "base"))
                       ("$lte"      . ("x"         "y"   "base"))
                       ("$gt"       . ("x"         "y"   "base"))
                       ("$gte"      . ("x"         "y"   "base"))
                       ("$join"     . ("variable"  "separator" "prefix"))
                       ("$slice"    . ("variable"  "start" "end" "separator"))
                       ("$getmulti" . ("variable"  "index" "separator"))
                       ("$trim"     . ("text"      "char"))
                       ("$strip"    . ("text"))
                       ("$lower"    . ("text"))
                       ("$upper"    . ("text"))
                       ("$title"    . ("text"))
                       ("$reverse"  . ("text"))
                       ("$len"      . ("text")))))))
    (or (and named (nth index named))
        (nth index picard--generic-arg-names)
        (format "arg%d" (1+ index)))))

;;;; Context detection — traditional (regex) path

(defun picard-eldoc--function-context-traditional ()
  "Return context information when point is inside a Picard function call.

Searches backward for the nearest enclosing `$name(' pattern whose
parentheses are balanced (i.e. the closing `)' has not yet been passed
by point).

Returns a plist with:
  :name        function name string including `$'
  :info        plist from `picard-function-info'
  :current-arg zero-based index of the argument at point

Returns nil when point is not inside any function call."
  (save-excursion
    (let ((orig-point (point))
          (result nil))
      ;; Search backward for $name(.  Stop when we find one whose matching
      ;; closing paren is at or after orig-point.
      (catch 'found
        (while (re-search-backward
                "\\$\\([a-zA-Z_][a-zA-Z0-9_]*\\)(" nil t)
          (let* ((func-name  (concat "$" (match-string-no-properties 1)))
                 (paren-open (1- (match-end 0))) ; position of `('
                 (depth 0)
                 (current-arg 0)
                 (found-close nil))
            ;; Walk forward from paren-open to find the matching `)'.
            (save-excursion
              (goto-char paren-open)
              (while (and (not (eobp)) (not found-close))
                (let ((ch (char-after)))
                  (cond
                   ((eq ch ?\()
                    (setq depth (1+ depth)))
                   ((eq ch ?\))
                    (setq depth (1- depth))
                    (when (= depth 0)
                      (setq found-close (point))))
                   ;; Count commas at the top level to track argument index.
                   ((and (eq ch ?,) (= depth 1)
                         (<= (point) orig-point))
                    (setq current-arg (1+ current-arg)))))
                (forward-char 1)))
            ;; Accept this call if orig-point is inside its argument list.
            (when (and found-close
                       (>= orig-point (1+ paren-open))
                       (<= orig-point found-close))
              (let ((info (picard-function-info func-name)))
                (when info
                  (setq result (list :name func-name
                                     :info info
                                     :current-arg current-arg))
                  (throw 'found result)))))))
      result)))

(defun picard-eldoc--variable-context-traditional ()
  "Return context information when point is inside a `%varname%' reference.

Examines the characters between the start of the current line and point.
An odd number of `%' characters means point is inside a variable name.

Returns a plist with:
  :name  variable name string (without `%' delimiters)
  :info  plist from `picard-tag-info', or nil for unknown variables

Returns nil when point is not inside any variable reference."
  (save-excursion
    (let* ((line-start (line-beginning-position))
           (text       (buffer-substring-no-properties line-start (point)))
           (pct-count  (cl-count ?% text)))
      (when (cl-oddp pct-count)
        ;; Point is between an opening and closing `%'.
        ;; Extract the variable name under or behind point.
        (let ((var-name
               (save-excursion
                 (let ((end (progn
                              (skip-chars-forward "a-zA-Z0-9_")
                              (point)))
                       (beg (progn
                              (skip-chars-backward "a-zA-Z0-9_")
                              (point))))
                   (buffer-substring-no-properties beg end)))))
          (when (> (length var-name) 0)
            (list :name var-name
                  :info (picard-tag-info var-name))))))))

;;;; Context detection — tree-sitter path

(defun picard-eldoc--treesit-available-p ()
  "Return non-nil when tree-sitter is available and active in the buffer."
  (and (fboundp 'treesit-parser-list)
       (treesit-parser-list)))

(defun picard-eldoc--function-context-treesit ()
  "Return function context plist using the tree-sitter syntax tree.

Walks from the node at point up through ancestors looking for a
`function_call' node.  Returns a plist compatible with the traditional
path (keys :name, :info, :current-arg) or nil."
  (when (picard-eldoc--treesit-available-p)
    (condition-case nil
        (let* ((node    (treesit-node-at (point)))
               (current node)
               (result  nil))
          (while (and current (null result))
            (when (string= (treesit-node-type current) "function_call")
              (let* ((name-node  (treesit-node-child-by-field-name
                                  current "name"))
                     (func-name  (when name-node
                                   (concat "$" (treesit-node-text name-node t))))
                     (info       (when func-name
                                   (picard-function-info func-name)))
                     (current-arg
                      (when info
                        (let* ((open-paren (treesit-node-end name-node))
                               (depth 0)
                               (arg-idx 0)
                               (limit (point)))
                          (save-excursion
                            (goto-char open-paren)
                            (while (and (< (point) limit) (not (eobp)))
                              (let ((ch (char-after)))
                                (cond
                                 ((eq ch ?\()
                                  (setq depth (1+ depth)))
                                 ((eq ch ?\))
                                  (setq depth (1- depth)))
                                 ((and (eq ch ?,) (= depth 1))
                                  (setq arg-idx (1+ arg-idx))))
                                (forward-char 1))))
                          arg-idx))))
                (when info
                  (setq result (list :name func-name
                                     :info info
                                     :current-arg current-arg)))))
            (setq current (treesit-node-parent current)))
          result)
      (error nil))))

(defun picard-eldoc--variable-context-treesit ()
  "Return variable context plist using the tree-sitter syntax tree.

Looks for a `variable' node at or enclosing point.  Returns a plist
with :name and :info keys, or nil."
  (when (picard-eldoc--treesit-available-p)
    (condition-case nil
        (let* ((node    (treesit-node-at (point)))
               (current node)
               (result  nil))
          (while (and current (null result))
            (when (string= (treesit-node-type current) "variable")
              (let* ((var-name (treesit-node-text current t))
                     ;; Strip surrounding `%' delimiters if present.
                     (bare-name
                      (if (and (> (length var-name) 1)
                               (eq (aref var-name 0) ?%)
                               (eq (aref var-name (1- (length var-name))) ?%))
                          (substring var-name 1 (1- (length var-name)))
                        var-name)))
                (setq result (list :name bare-name
                                   :info (picard-tag-info bare-name)))))
            (setq current (treesit-node-parent current)))
          result)
      (error nil))))

;;;; Eldoc function

(defun picard-eldoc-function (cb &rest _ignored)
  "Eldoc documentation function for Picard Tagger Script.

CB is the callback supplied by Eldoc (Emacs 28+).  When CB is non-nil
the result string is passed to it; otherwise it is returned directly.
This matches the multi-source protocol described in
`(info \"(emacs) Eldoc\")'.

The function first determines whether point is inside a function call or
a variable reference, then formats an appropriate documentation string.

Function signature format:
  $funcname(arg1, arg2[, opt]) — category: one-line description.

Variable format:
  %varname% — category: one-line description."
  (let* ((func-ctx
          (if (picard-eldoc--treesit-available-p)
              (picard-eldoc--function-context-treesit)
            (picard-eldoc--function-context-traditional)))
         (var-ctx
          (unless func-ctx
            (if (picard-eldoc--treesit-available-p)
                (picard-eldoc--variable-context-treesit)
              (picard-eldoc--variable-context-traditional))))
         (doc-string
          (cond
           (func-ctx
            (picard-eldoc--make-signature
             (plist-get func-ctx :name)
             (plist-get func-ctx :info)
             (plist-get func-ctx :current-arg)))
           (var-ctx
            (let* ((name (plist-get var-ctx :name))
                   (info (plist-get var-ctx :info))
                   (cat  (if info (plist-get info :category) "unknown"))
                   (doc  (if info (plist-get info :doc) "User-defined variable.")))
              (format "%%%s%% — %s: %s"
                      name cat doc)))
           (t nil))))
    (if cb
        (when doc-string
          (funcall cb doc-string))
      doc-string)))

;;;; Setup entry point

(defun picard-eldoc-setup ()
  "Register the Picard Eldoc function in the current buffer.

Adds `picard-eldoc-function' to the buffer-local value of
`eldoc-documentation-functions' (Emacs 28+) or sets the legacy
`eldoc-documentation-function' variable on older Emacs versions.

Call this from a major mode hook, typically alongside `eldoc-mode':

  (add-hook \\='picard-mode-hook
            (lambda ()
              (picard-eldoc-setup)
              (eldoc-mode 1)))"
  (if (boundp 'eldoc-documentation-functions)
      ;; Emacs 28+: multi-source protocol.
      (add-hook 'eldoc-documentation-functions #'picard-eldoc-function nil t)
    ;; Emacs < 28: single function protocol.
    (setq-local eldoc-documentation-function #'picard-eldoc-function)))

(provide 'picard-eldoc)
;;; picard-eldoc.el ends here
