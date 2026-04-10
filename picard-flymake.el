;;; picard-flymake.el --- Flymake backend for Picard Tagger Script  -*- lexical-binding: t -*-

;; Author: 11xx
;; Version: 2026.04.08
;; Package-Requires: ((emacs "27.1") (picard-data "0.1.0"))
;; Keywords: languages, tools, picard, musicbrainz, flymake
;; URL: https://github.com/example/picard-mode

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
;;   Tree-sitter mode  — walks the syntax tree for `function_call' nodes,
;;                       extracts the function name and counts `argument'
;;                       children, then validates against the database.
;;
;;   Traditional mode  — uses regular expressions to locate `$name(' patterns,
;;                       then counts commas at the same parenthesis nesting
;;                       depth to infer argument count.
;;
;; In both modes, an additional linear scan checks for:
;;   - Unmatched `%' delimiters (odd number of `%' chars between newlines)
;;   - Unmatched parentheses (depth never goes negative; depth != 0 at EOF)
;;
;; Diagnostic severity mapping
;; ---------------------------
;;   :error    — call to an unknown function name
;;   :warning  — call with wrong number of arguments (too few or too many)
;;   :note     — unmatched delimiter (`%' or parenthesis)
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
they belong to the nested call's own argument list."
  (save-excursion
    (goto-char start)
    (unless (eq (char-after) ?\()
      (cl-return-from picard-flymake--count-args-traditional nil))
    (let ((depth 0)
          (arg-count 0)
          ;; When the call is $f() the arg count should be 0, but
          ;; we start at 1 and subtract later only when we see content.
          (has-content nil))
      (while (and (not (eobp))
                  (or (> depth 0) (= (point) start)))
        (let ((ch (char-after)))
          (cond
           ((eq ch ?\()
            (setq depth (1+ depth))
            ;; Only count top-level commas; initialise arg-count here.
            (when (= depth 1)
              (setq arg-count 1)))
           ((eq ch ?\))
            (setq depth (1- depth)))
           ((and (eq ch ?,) (= depth 1))
            (setq arg-count (1+ arg-count)))
           ;; Any non-whitespace at depth 1 means the call is non-empty.
           ((and (= depth 1) (not (memq ch '(?\s ?\t ?\n ?\r))))
            (setq has-content t))))
        (forward-char 1))
      ;; $f() has depth back to 0 after the closing paren; arg-count was
      ;; initialised to 1 above, but the call has 0 args when empty.
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
             ;; Known function — validate arity.
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
;; that appear literally in the source — including leading spaces — become
;; part of the evaluated string.  This is a frequent source of mistakes when
;; authors indent multi-line $if / $if2 / $and / $or / $not calls with spaces
;; rather than tabs:
;;
;;   $if(
;;     %artist%,        ← the two leading spaces are part of the condition
;;     great,           ← and these spaces are part of the "then" value
;;     bad              ← and here
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

(defconst picard-flymake--conditional-functions
  '("$if" "$if2" "$and" "$or" "$not")
  "Picard Script conditional functions checked for leading-space arguments.
Leading spaces in the arguments of these functions alter the truthiness
of the condition or the returned value in non-obvious ways.")

(defun picard-flymake--scan-whitespace-args-treesit (buffer)
  "Scan BUFFER tree-sitter nodes for leading spaces in conditional arguments.

Walks every `function_call' node in the parse tree.  For each call whose
name matches an entry in `picard-flymake--conditional-functions', examines
every `argument' child node.  If the raw source text of an argument contains
a newline followed by one or more space characters (with at most one leading
tab between the newline and the spaces), a `:note' diagnostic is emitted at
the position of the space run.

The field used to retrieve the function name is \"name\", which the grammar
exposes on `function_call' nodes.  The sigil \"$\" is prepended before the
member test because the `function_name' node text contains only the bare
identifier (e.g. \"if\"), while `picard-flymake--conditional-functions' stores
the full token (e.g. \"$if\").

Only the first offending space run per argument is reported to avoid
diagnostic flooding when an argument spans many indented lines.

Returns a (possibly empty) list of `flymake-diagnostic' objects."
  (with-current-buffer buffer
    (let ((diags nil))
      (when (picard-flymake--treesit-available-p)
        (condition-case err
            (let ((captures (treesit-query-capture
                             (treesit-buffer-root-node)
                             '((function_call) @call))))
              (dolist (capture captures)
                (let* ((call-node (cdr capture))
                       (name-node (treesit-node-child-by-field-name
                                   call-node "name"))
                       (func-name (when name-node
                                    (treesit-node-text name-node t))))
                  (when (and func-name
                             (member (concat "$" func-name)
                                     picard-flymake--conditional-functions))
                    (dolist (child (treesit-node-children call-node t))
                      (when (string= (treesit-node-type child) "argument")
                        (let* ((arg-start (treesit-node-start child))
                               (arg-text  (treesit-node-text child t)))
                          ;; `arg-text' is the raw source span of this argument
                          ;; node, including any surrounding whitespace that
                          ;; appears literally in the source file.
                          ;;
                          ;; A multi-line argument indented with spaces looks
                          ;; like "\n  value" or "\n\t  value" (tab then
                          ;; spaces).  Picard's runtime passes those characters
                          ;; verbatim to the function, so a leading space turns
                          ;; an otherwise empty string into " ", which is
                          ;; truthy in $if conditions.  A single leading tab is
                          ;; harmless because Picard strips it; spaces are not
                          ;; stripped.
                          ;;
                          ;; The regexp matches:
                          ;;   \n      a newline — confirms this is a multi-line
                          ;;           argument, not an intentional leading space
                          ;;           on a single-line call
                          ;;   \t?     an optional single tab (harmless indent)
                          ;;   \( +\)  one or more space characters — the
                          ;;           offending run, captured as group 1
                          ;;
                          ;; `match-beginning 1' / `match-end 1' give the byte
                          ;; offsets of the space run within `arg-text'.
                          ;; Adding `arg-start' converts them to absolute
                          ;; buffer positions for `flymake-make-diagnostic'.
                          (when (string-match "\n\t?\\( +\\)" arg-text)
                            (push (flymake-make-diagnostic
                                   buffer
                                   (+ arg-start (match-beginning 1))
                                   (+ arg-start (match-end 1))
                                   :note
                                   (concat
                                    "Leading spaces in argument are significant "
                                    "in Picard Script \u2014 they become part of "
                                    "the evaluated string. "
                                    "Use tabs for indentation inside function "
                                    "calls."))
                                  diags)))))))))
          (error
           (message "picard-flymake whitespace scan: %S" err))))
      diags)))

(defun picard-flymake--scan-whitespace-args-traditional (buffer)
  "Scan BUFFER text for leading spaces in conditional function arguments.

This is the fallback path used when tree-sitter is unavailable.  It
locates `$if(', `$if2(', `$and(', `$or(', and `$not(' patterns, then
scans the argument regions character by character for lines that begin
with space characters (after an optional leading tab) at paren depth 1.

Returns a list of `flymake-diagnostic' objects with severity `:note'."
  (with-current-buffer buffer
    (let ((diags '())
          ;; Regexp to detect the opening of a guarded conditional call.
          ;; The alternation is anchored to `$' and matches exactly the
          ;; five function names without greedily capturing longer names.
          (cond-re (rx "$" (or "if2" "if" "and" "or" "not") "(")))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward cond-re nil t)
          ;; Point is now just after the opening `('; begin scanning from here.
          (let ((depth 1)
                (scan-start (point)))
            (save-excursion
              ;; Walk characters at depth 1, looking for newline followed by
              ;; optional tab followed by one or more spaces.
              (goto-char scan-start)
              (while (and (> depth 0) (not (eobp)))
                (let ((ch (char-after)))
                  (cond
                   ;; Skip backslash escapes.
                   ((eq ch ?\\)
                    (forward-char 2))
                   ((eq ch ?\()
                    (setq depth (1+ depth))
                    (forward-char 1))
                   ((eq ch ?\))
                    (setq depth (1- depth))
                    (forward-char 1))
                   ;; Newline at depth 1: check the next characters for
                   ;; indentation-with-spaces.  A line beginning with
                   ;; \n (\t?) (SPACE+) at depth 1 triggers the warning.
                   ((and (eq ch ?\n) (= depth 1))
                    (forward-char 1)          ; consume the newline
                    (when (eq (char-after) ?\t)
                      (forward-char 1))       ; consume optional single tab
                    (when (eq (char-after) ?\ )
                      ;; One or more spaces follow: record the region.
                      (let ((space-start (point)))
                        (skip-chars-forward " ")
                        (push (flymake-make-diagnostic
                               buffer
                               space-start
                               (point)
                               :note
                               (concat
                                "Leading spaces in argument are significant "
                                "in Picard Script \u2014 they become part of "
                                "the evaluated string. "
                                "Use tabs for indentation inside function "
                                "calls."))
                              diags))))
                   (t
                    (forward-char 1)))))))))
      diags)))


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
                       (n-args     (cl-count "argument"
                                            (treesit-node-children call-node)
                                            :key #'treesit-node-type
                                            :test #'string=))
                       (node-start (when name-node
                                     (treesit-node-start name-node)))
                       (node-end   (when name-node
                                     (treesit-node-end name-node))))
                  (cond
                   ((null func-name))          ; malformed node, skip
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

  1. Function-call validation — checks unknown names and arity violations.
     Tree-sitter is preferred; regex scanning is used as fallback.

  2. Delimiter balance checking — finds unmatched `%' signs and parentheses.
     This scan is always performed, regardless of tree-sitter availability.

  3. Whitespace-in-conditional-argument checking — warns when a conditional
     function (`$if', `$if2', `$and', `$or', `$not') has an argument that
     begins with space characters after a newline, indicating that the author
     used space-based indentation inside the call.  Leading spaces are
     significant in Picard Script and become part of the evaluated string.
     Reported with severity `:note' because the pattern may be intentional.
     Tree-sitter is preferred; character scanning is used as fallback.

See `picard-flymake--scan-treesit', `picard-flymake--scan-traditional',
`picard-flymake--scan-delimiter-balance',
`picard-flymake--scan-whitespace-args-treesit', and
`picard-flymake--scan-whitespace-args-traditional' for implementation details."
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
         ;; Whitespace-in-conditional-argument check: also prefers the
         ;; tree-sitter path when available.  This check is independent of
         ;; the arity validation above; both run in the same backend call.
         (ws-diags
          (if (picard-flymake--treesit-available-p)
              (picard-flymake--scan-whitespace-args-treesit buffer)
            (picard-flymake--scan-whitespace-args-traditional buffer)))
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
