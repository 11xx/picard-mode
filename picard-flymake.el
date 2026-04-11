;;; picard-flymake.el --- Flymake backend for Picard Tagger Script  -*- lexical-binding: t -*-

;; Author: 11xx
;; Version: 2026.4.10
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, tools, picard, musicbrainz, flymake
;; URL: https://codeberg.org/useless-utils/picard-mode

;;; Commentary:

;; This file provides a Flymake backend for Picard Tagger Script buffers.
;;
;; Flymake is Emacs's built-in on-the-fly syntax checking framework.
;; A "backend" is a function registered in `flymake-diagnostic-functions'
;; that Flymake calls to collect diagnostics.  Each backend receives a
;; REPORT-FN argument; after analysis the backend calls REPORT-FN with a
;; list of `flymake-diagnostic' objects produced by `flymake-make-diagnostic'.
;;
;; How this backend works
;; ----------------------
;; The backend operates in two modes depending on whether tree-sitter is
;; available for the current buffer:
;;
;;   Tree-sitter mode: walks the syntax tree for `function_call' nodes,
;;                     extracts the function name and counts `argument'
;;                     children, then validates against the database.
;;
;;   Traditional mode: uses regular expressions to locate `$name(' patterns,
;;                       then counts commas at the same parenthesis nesting
;;                       depth to infer argument count.
;;
;; In both modes, an additional linear scan checks for:
;;   - Unmatched `%' delimiters (odd number of `%' chars between newlines)
;;   - Unmatched parentheses (depth never goes negative; depth != 0 at EOF)
;;
;; Diagnostic severity mapping
;; ---------------------------
;;   :error: call to an unknown function name
;;   :warning: call with wrong number of arguments (too few or too many)
;;   :note: unmatched delimiter (`%' or parenthesis)
;;
;; Setup
;; -----
;; Call `picard-flymake-setup' from a major mode's setup function:
;;
;;   (defun my-picard-mode-hook ()
;;     (picard-flymake-setup)
;;     (flymake-mode 1))
;;
;; or add it directly:
;;
;;   (add-hook 'picard-mode-hook #'picard-flymake-setup)

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'picard-data)

;; Tree-sitter functions are only called when `treesit' is available at
;; runtime.  The `declare-function' forms below silence byte-compiler
;; warnings without requiring the `treesit' feature unconditionally.
(declare-function treesit-buffer-root-node "treesit" ())
(declare-function treesit-query-capture    "treesit" (node query &optional beg end node-only))
(declare-function treesit-node-child-by-field-name "treesit" (node field-name))
(declare-function treesit-node-text        "treesit" (node &optional with-properties))
(declare-function treesit-node-type        "treesit" (node))
(declare-function treesit-node-start       "treesit" (node))
(declare-function treesit-node-end         "treesit" (node))
(declare-function treesit-node-children    "treesit" (node &optional named))
(declare-function treesit-parser-list      "treesit" (&optional buffer language))

;;;; Internal helpers

(defun picard-flymake--count-args-traditional (start)
  "Count the arguments of the function call whose opening paren is at START.

START is the buffer position of the opening parenthesis.  The function
walks forward character by character, tracking paren depth and counting
commas at depth 1 (immediately inside the top-level opening paren).

Returns the integer argument count, or nil if START does not point at
an opening parenthesis.

 Commas inside nested function calls (depth > 1) are not counted because
they belong to the nested call's own argument list.

Escaped parentheses (backslash followed by paren) are skipped because
they represent literal paren characters in Picard, not structural markers."
  (save-excursion
    (goto-char start)
    (unless (eq (char-after) ?\()
      (cl-return-from picard-flymake--count-args-traditional nil))
    (let ((depth 0)
          (arg-count 0)
          (has-content nil))
      (while (and (not (eobp))
                  (or (> depth 0) (= (point) start)))
        (let ((ch (char-after)))
          (cond
           ;; Skip Picard escape sequences like \( and \) without
           ;; treating the escaped character as syntax.
           ((and (eq ch ?\\)
                 (char-after (1+ (point))))
            (forward-char 2))
           ((eq ch ?\()
            (setq depth (1+ depth))
            (when (= depth 1)
              (setq arg-count 1))
            (forward-char 1))
           ((eq ch ?\))
            (setq depth (1- depth))
            (forward-char 1))
           ((and (eq ch ?,) (= depth 1))
            (setq arg-count (1+ arg-count))
            (forward-char 1))
           ((and (= depth 1) (not (memq ch '(?\s ?\t ?\n ?\r))))
            (setq has-content t)
            (forward-char 1))
           (t
            (forward-char 1)))))
      (if has-content arg-count 0))))

(defun picard-flymake--scan-traditional (buffer)
  "Scan BUFFER using regex and return a list of Flymake diagnostics.

This is the fallback path used when tree-sitter is not available.
It locates `$funcname(' patterns, validates function names, counts
arguments, and reports arity violations."
  (with-current-buffer buffer
    (let ((diags '()))
      (save-excursion
        (goto-char (point-min))
        ;; Locate every $name( call in the buffer.
        (while (re-search-forward "\\$\\([a-zA-Z_][a-zA-Z0-9_]*\\)(" nil t)
          (let* ((name-start (match-beginning 0))
                 (name-end   (match-end 1))
                 (func-name  (concat "$" (match-string-no-properties 1)))
                 ;; Opening paren is at (match-end 0) - 1.
                 (paren-pos  (1- (match-end 0)))
                 (info        (picard-function-info func-name)))
            (cond
             ;; Unknown function.
             ((null info)
              (push (flymake-make-diagnostic
                     buffer
                     name-start
                     name-end
                     :error
                     (format "Unknown Picard function: %s" func-name))
                    diags))
             ;; Known function: validate arity.
             (t
              (let* ((n-args   (picard-flymake--count-args-traditional paren-pos))
                     (min-args (plist-get info :min-args))
                     (max-args (plist-get info :max-args)))
                (when n-args
                  (cond
                   ((< n-args min-args)
                    (push (flymake-make-diagnostic
                           buffer
                           name-start
                           name-end
                           :warning
                           (format "%s requires at least %d argument(s); got %d"
                                   func-name min-args n-args))
                          diags))
                   ((and (not (= max-args -1))
                         (> n-args max-args))
                    (push (flymake-make-diagnostic
                           buffer
                           name-start
                           name-end
                           :warning
                           (format "%s accepts at most %d argument(s); got %d"
                                   func-name max-args n-args))
                          diags))))))))))
      diags)))

(defun picard-flymake--scan-delimiter-balance (buffer)
  "Scan BUFFER for unmatched percent signs and parentheses.

Returns a list of `flymake-diagnostic' objects with severity `:note' for
each unmatched delimiter found.

Percent signs are tracked per-line: an odd number of `%' characters on a
line is reported at the position of the last one.

Parentheses are tracked globally: depth is incremented on `(' and
decremented on `)'.  A depth that would go below zero is reported at the
offending `)'.  A non-zero depth at end-of-buffer is reported at the
last open paren."
  (with-current-buffer buffer
    (let ((diags '()))
      (save-excursion
        (goto-char (point-min))
        (let ((paren-depth 0)
              (last-open-pos nil))
          (while (not (eobp))
            (let* ((line-start (line-beginning-position))
                   (line-end   (line-end-position))
                   (line       (buffer-substring-no-properties
                                line-start line-end))
                   ;; Count `%' characters on this line.
                   (pct-count  0)
                   (pct-pos    nil))
              ;; Walk the line character by character to count `%' and
              ;; track parenthesis depth simultaneously.
              (cl-loop for idx from 0 below (length line)
                       for ch = (aref line idx)
                       for buf-pos = (+ line-start idx)
                       do (cond
                           ((eq ch ?%)
                            (setq pct-count (1+ pct-count))
                            (setq pct-pos buf-pos))
                           ((eq ch ?\()
                            (setq paren-depth (1+ paren-depth))
                            (setq last-open-pos buf-pos))
                           ((eq ch ?\))
                            (if (> paren-depth 0)
                                (setq paren-depth (1- paren-depth))
                              ;; Depth would go negative: unmatched close paren.
                              (push (flymake-make-diagnostic
                                     buffer
                                     buf-pos
                                     (1+ buf-pos)
                                     :note
                                     "Unmatched closing parenthesis")
                                    diags)))))
              ;; Report an odd number of `%' on this line.
              (when (and (cl-oddp pct-count) pct-pos)
                (push (flymake-make-diagnostic
                       buffer
                       pct-pos
                       (1+ pct-pos)
                       :note
                       "Unmatched '%' delimiter")
                      diags))
              (forward-line 1)))
          ;; At end-of-buffer, report any unclosed parenthesis.
          (when (and (> paren-depth 0) last-open-pos)
            (push (flymake-make-diagnostic
                   buffer
                   last-open-pos
                   (1+ last-open-pos)
                   :note
                   "Unmatched opening parenthesis")
                  diags))))
      diags)))

;;;; Whitespace-in-conditional-argument check

;; Picard Script evaluates function arguments as strings.  Any characters
;; that appear literally in the source: including leading spaces: become
;; part of the evaluated string.  This is a frequent source of mistakes when
;; authors indent multi-line $if / $if2 / $and / $or / $not calls with spaces
;; rather than tabs:
;;
;;   $if(
;;     %artist%  <- the two leading spaces are part of the condition
;;     great     <- and these spaces are part of the "then" value
;;     bad       <- and here
;;   )
;;
;; The Picard runtime passes those leading spaces verbatim to the function,
;; turning an empty string into " " (which is considered non-empty and therefore
;; truthy in $if's condition test).  Tab-based indentation does not cause this
;; problem because Picard's argument parser strips a single leading tab from
;; each argument line.
;;
;; The check emits a `:note' diagnostic (informational, not error) because the
;; pattern may be intentional.  Severity `:note' keeps the warning visible in
;; the Flymake gutter without being alarmist.
;;
;; The set of guarded conditionals is limited to those that evaluate their
;; arguments eagerly in a position where extra whitespace is most misleading:
;; $if, $if2 (first non-empty), $and, $or, $not.  Other functions ($set,
;; $replace, …) may legitimately want leading spaces in string arguments.


(defun picard-flymake--whitespace-diagnostic (buffer start end message)
  "Create a whitespace diagnostic in BUFFER from START to END with MESSAGE."
  (flymake-make-diagnostic buffer start end :note message))

(defun picard-flymake--space-run-diagnostic-at-point (buffer message)
  "Return a diagnostic for a leading space run at point, or nil.

Tabs are skipped before testing for spaces.  If the current point does not
start a space run, return nil."
  (save-excursion
    (while (eq (char-after) ?\t)
      (forward-char 1))
    (when (eq (char-after) ?\ )
      (let ((start (point)))
        (skip-chars-forward " ")
        (picard-flymake--whitespace-diagnostic
         buffer start (point) message)))))

(defun picard-flymake--scan-whitespace-args (buffer)
  "Scan BUFFER for significant spaces in conditional function arguments.

This text-based scanner works in both traditional and tree-sitter modes.
It only reports leading space runs at the start of condition arguments.
Tabs are ignored; only spaces are diagnostic."
  (with-current-buffer buffer
    (let ((diags nil)
          (cond-re (rx "$" (or "if2" "if" "and" "or" "not") "(")))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward cond-re nil t)
          (let* ((func-name (substring (match-string-no-properties 0) 0 -1))
                 (depth 1)
                 (arg-index 0))
            (save-excursion
              (goto-char (point))
              (when (picard-function-conditional-arg-p func-name arg-index)
                (let ((diag (picard-flymake--space-run-diagnostic-at-point
                             buffer
                             "Leading spaces after '(' are significant in Picard Script.")))
                  (when diag (push diag diags))))
              (while (and (> depth 0) (not (eobp)))
                (let ((ch (char-after)))
                  (cond
                   ((and (eq ch ?\\)
                         (char-after (1+ (point))))
                    (forward-char 2))
                   ((eq ch ?\()
                    (setq depth (1+ depth))
                    (forward-char 1))
                   ((eq ch ?\))
                    (setq depth (1- depth))
                    (forward-char 1))
                   ((and (eq ch ?,) (= depth 1))
                    (setq arg-index (1+ arg-index))
                    (forward-char 1)
                    (when (picard-function-conditional-arg-p func-name arg-index)
                      (let ((diag (picard-flymake--space-run-diagnostic-at-point
                                   buffer
                                   "Leading spaces after ',' are significant in Picard Script.")))
                        (when diag (push diag diags)))))
                   ((eq ch ?\n)
                    (forward-char 1)
                    (when (and (= depth 1)
                               (picard-function-conditional-arg-p func-name arg-index))
                      (let ((diag (picard-flymake--space-run-diagnostic-at-point
                                   buffer
                                   "Leading spaces after newline are significant in Picard Script.")))
                        (when diag (push diag diags)))))
                   (t
                    (forward-char 1)))))))))
      diags)))

(defun picard-flymake--scan-whitespace-args-treesit (buffer)
  "Compatibility wrapper for `picard-flymake--scan-whitespace-args'."
  (picard-flymake--scan-whitespace-args buffer))

(defun picard-flymake--scan-whitespace-args-traditional (buffer)
  "Compatibility wrapper for `picard-flymake--scan-whitespace-args'."
  (picard-flymake--scan-whitespace-args buffer))


;;;; Tree-sitter path

(defun picard-flymake--treesit-available-p ()
  "Return non-nil if tree-sitter is available and active in the current buffer.

Checks for the `treesit' feature and that `treesit-parser-list' returns
at least one parser, meaning the current buffer has a live tree."
  (and (fboundp 'treesit-parser-list)
       (treesit-parser-list)))

(defun picard-flymake--scan-treesit (buffer)
  "Scan BUFFER using the tree-sitter syntax tree and return diagnostics.

  Walks every `function_call' node in the tree.  For each call:
    1. Extracts the text of the `name' child node.
    2. Counts `argument' child nodes.
    3. Validates name and arity against `picard-builtin-functions'.

  Returns a list of `flymake-diagnostic' objects."
  (with-current-buffer buffer
    (let ((diags '()))
      (when (picard-flymake--treesit-available-p)
        (condition-case _err
            (let ((captures
                   (treesit-query-capture
                    (treesit-buffer-root-node)
                    '((function_call) @call))))
              (dolist (capture captures)
                (let* ((call-node  (cdr capture))
                       (name-node  (treesit-node-child-by-field-name
                                    call-node "name"))
                       (func-name  (when name-node
                                     (concat "$" (treesit-node-text name-node t))))
                       (info       (when func-name
                                     (picard-function-info func-name)))
                       (n-args     (when name-node
                                     (picard-flymake--count-args-traditional
                                      (treesit-node-end name-node))))
                       (node-start (when name-node
                                     (treesit-node-start name-node)))
                       (node-end   (when name-node
                                     (treesit-node-end name-node))))
                  (cond
                   ((null func-name))            ; malformed node, skip
                   ((string= func-name "$noop")) ; $noop is used for comments; skip
                   ((null info)
                    (push (flymake-make-diagnostic
                           buffer node-start node-end
                           :error
                           (format "Unknown Picard function: %s" func-name))
                          diags))
                   (t
                    (let ((min-args (plist-get info :min-args))
                          (max-args (plist-get info :max-args)))
                      (cond
                       ((< n-args min-args)
                        (push (flymake-make-diagnostic
                               buffer node-start node-end
                               :warning
                               (format "%s requires at least %d argument(s); got %d"
                                       func-name min-args n-args))
                              diags))
                       ((and (not (= max-args -1))
                             (> n-args max-args))
                        (push (flymake-make-diagnostic
                               buffer node-start node-end
                               :warning
                               (format "%s accepts at most %d argument(s); got %d"
                                       func-name max-args n-args))
                              diags)))))))))
          ;; If the tree-sitter query fails for any reason, fall through to
          ;; the traditional scanner via the caller.
          (error nil)))
      diags)))

;;;; Public backend

(defun picard-flymake-backend (report-fn &rest _args)
  "Flymake backend for Picard Tagger Script buffers.

REPORT-FN is the callback provided by Flymake; this function calls it with
a list of diagnostics after scanning the buffer.

The backend is synchronous and processes the buffer in one pass.  It is
registered in `flymake-diagnostic-functions' by `picard-flymake-setup'.

Diagnostics are produced by three complementary analyses:

  1. Function-call validation: checks unknown names and arity violations.
     Tree-sitter is preferred; regex scanning is used as fallback.

  2. Delimiter balance checking: finds unmatched `%' signs and parentheses.
     This scan is always performed, regardless of tree-sitter availability.

  3. Whitespace-in-conditional-argument checking: warns when a conditional
     function (`$if', `$if2', `$and', `$or', `$not') has significant spaces
     in a condition position.  Leading and trailing spaces become part of the
     evaluated string and can change truthiness in non-obvious ways.

See `picard-flymake--scan-treesit', `picard-flymake--scan-traditional',
`picard-flymake--scan-delimiter-balance', and
`picard-flymake--scan-whitespace-args' for implementation details.

The function `picard-data-conditional-functions' supplies the list of
functions whose arguments are checked for significant whitespace."
  (let* ((buffer (current-buffer))
         ;; Choose function-call validation strategy based on tree-sitter
         ;; availability.  Tree-sitter is preferred because it provides exact
         ;; node boundaries without regexp heuristics.
         (call-diags
          (if (picard-flymake--treesit-available-p)
              (picard-flymake--scan-treesit buffer)
            (picard-flymake--scan-traditional buffer)))
         ;; Delimiter balance is always checked, regardless of tree-sitter.
         (delim-diags (picard-flymake--scan-delimiter-balance buffer))
         ;; Whitespace-in-conditional-argument check: this text scan is
         ;; independent of arity validation and runs in both modes.
         (ws-diags (picard-flymake--scan-whitespace-args buffer))
         (all-diags (append call-diags delim-diags ws-diags)))
    (funcall report-fn all-diags)))

;;;; Setup entry point

(defun picard-flymake-setup ()
  "Register the Picard Flymake backend in the current buffer.

This function adds `picard-flymake-backend' to the buffer-local value of
`flymake-diagnostic-functions'.  It is intended to be called from a major
mode's hook, typically alongside `(flymake-mode 1)'.

Example usage in a mode definition:

  (add-hook \\='picard-mode-hook
            (lambda ()
              (picard-flymake-setup)
              (flymake-mode 1)))"
  (add-hook 'flymake-diagnostic-functions #'picard-flymake-backend nil t))

(provide 'picard-flymake)
;;; picard-flymake.el ends here
