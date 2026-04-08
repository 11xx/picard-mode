;;; picard-completion.el --- Completion-at-point for Picard Tagger Script  -*- lexical-binding: t -*-

;; Author: 11xx
;; Version: 2026.04.08
;; Package-Requires: ((emacs "27.1") (picard-data "0.1.0"))
;; Keywords: languages, tools, picard, musicbrainz, completion
;; URL: https://github.com/example/picard-mode

;;; Commentary:

;; This file provides completion-at-point (CAPF) for Picard Tagger Script.
;;
;; Emacs's CAPF protocol
;; ---------------------
;; Completion-at-point works through `completion-at-point-functions', a
;; buffer-local hook.  Each function on the hook is called with no arguments.
;; If the function can provide completions for the text at point it returns a
;; list of the form:
;;
;;   (START END TABLE . PROPERTIES)
;;
;; where:
;;   START      — buffer position of the start of the completion region.
;;   END        — buffer position of the end of the completion region.
;;   TABLE      — a completion table: a list, hash table, or function.
;;   PROPERTIES — a plist of metadata accepted by `completion-at-point'.
;;
;; Common properties:
;;   :annotation-function  — called with each candidate to produce the
;;                           annotation string shown in the *Completions* buffer
;;                           and in Company/Corfu popups.
;;   :company-kind         — used by Company.el to choose an icon (optional).
;;   :exclusive            — when `yes', prevents other CAPF functions from
;;                           running if this one returned a result.
;;
;; If the function cannot complete at point it must return nil so the next
;; function on the hook gets a chance.
;;
;; Context detection
;; -----------------
;; Two contexts trigger completion:
;;
;;   After `$'   — complete function names.  The region extends from the `$'
;;                 (or from one character after it) to point.  Candidates are
;;                 taken from `picard-function-names'.  Annotations show the
;;                 functional category and arity summary.
;;
;;   Inside `%…%' — complete variable/tag names.  The region extends from the
;;                  character after the opening `%' to point.  Candidates are
;;                  taken from `picard-tag-names'.  Annotations show the
;;                  category (basic-tag or hidden-variable).
;;
;; Annotation format
;; -----------------
;; Functions:   [mathematical 2+]
;;              [conditional 2..3]
;;              [text 1]
;;
;; Variables:   [basic-tag]
;;              [hidden-variable]
;;
;; Setup
;; -----
;;   (add-hook \\='picard-mode-hook #\\='picard-completion-setup)

;;; Code:

(require 'cl-lib)
(require 'picard-data)

;;;; Annotation helpers

(defun picard-completion--function-annotation (candidate)
  "Return an annotation string for the function name CANDIDATE.

CANDIDATE is a string like \"$if\".  The annotation summarises the
functional category and accepted arity, formatted as:

  [conditional 2..3]   — fixed range
  [mathematical 2+]    — variadic (min-args or more)
  [miscellaneous 0+]   — variadic with zero required args
  [information 0]      — exactly zero args"
  (let ((info (picard-function-info candidate)))
    (if (null info)
        ""
      (let* ((cat      (plist-get info :category))
             (min-args (plist-get info :min-args))
             (max-args (plist-get info :max-args))
             (arity
              (cond
               ((= max-args -1)
                ;; Variadic: show minimum followed by `+'.
                (format "%d+" min-args))
               ((= min-args max-args)
                ;; Exact arity.
                (number-to-string min-args))
               (t
                ;; Range.
                (format "%d..%d" min-args max-args)))))
        (format " [%s %s]" cat arity)))))

(defun picard-completion--tag-annotation (candidate)
  "Return an annotation string for the tag or variable name CANDIDATE.

CANDIDATE is a bare string like \"artist\" or \"_filename\".  The
annotation shows the category:

  [basic-tag]
  [hidden-variable]"
  (let ((info (picard-tag-info candidate)))
    (if (null info)
        ""
      (format " [%s]" (plist-get info :category)))))

;;;; Context detection

(defun picard-completion--function-bounds ()
  "Return (START . END) of the function name fragment starting after `$'.

Returns nil when point is not after a `$' or when the `$' begins a tag
context (which uses `%' delimiters).

START is the buffer position of the `$' sign.
END   is the buffer position of the end of the current word at point."
  (save-excursion
    ;; Walk backward over valid function-name characters.
    (let ((end (point)))
      (skip-chars-backward "a-zA-Z0-9_")
      (when (and (> (point) (point-min))
                 (eq (char-before) ?$))
        ;; Include the `$' in the completion region so the full
        ;; candidate (which includes `$') replaces the right text.
        (cons (1- (point)) end)))))

(defun picard-completion--variable-bounds ()
  "Return (START . END) of the variable name fragment inside `%…'.

Returns nil when point is not inside a variable reference.

The test is: count `%' characters from the start of the line to point;
an odd count means point is inside a variable.

START is the buffer position of the character immediately after the
opening `%'.
END   is the buffer position of the end of the current word at point."
  (save-excursion
    (let* ((line-start (line-beginning-position))
           (text (buffer-substring-no-properties line-start (point)))
           (pct-count (cl-count ?% text)))
      (when (cl-oddp pct-count)
        (let ((end (progn (skip-chars-forward "a-zA-Z0-9_") (point))))
          (skip-chars-backward "a-zA-Z0-9_")
          ;; START is one past the `%' delimiter.
          (cons (point) end))))))

;;;; Completion table helpers

(defun picard-completion--function-table ()
  "Return a completion table for Picard built-in function names.

The table is a plain list; each element includes the leading `$' sign.
`completion-table-dynamic' wraps it so Emacs can request completions
lazily."
  (completion-table-dynamic
   (lambda (_prefix) (picard-function-names))))

(defun picard-completion--tag-table ()
  "Return a completion table for Picard built-in tag and variable names.

The table is a plain list of bare names (without `%' delimiters).
`completion-table-dynamic' wraps it for lazy delivery."
  (completion-table-dynamic
   (lambda (_prefix) (picard-tag-names))))

;;;; CAPF function

(defun picard-completion-at-point ()
  "Completion-at-point function for Picard Tagger Script.

Returns a CAPF specification list when point is positioned for function
or variable completion, or nil when neither context applies.

Function completion is triggered after `$': candidates are all built-in
function names (including the `$' prefix).  The completion region covers
from the `$' character to point, so Emacs replaces the entire `$name'
fragment.

Variable completion is triggered inside `%…%': candidates are all
built-in tag and variable names.  The region covers the bare name (not
the `%' delimiters).  A `%' exit function is installed so that accepting
a completion automatically appends the closing `%' if it is absent.

Each candidate is annotated via `:annotation-function' to show category
and arity information (see `picard-completion--function-annotation' and
`picard-completion--tag-annotation').

This function should be added to `completion-at-point-functions' by
calling `picard-completion-setup'."
  (cond
   ;; ---- Function completion ----
   ((picard-completion--function-bounds)
    (let* ((bounds (picard-completion--function-bounds))
           (start  (car bounds))
           (end    (cdr bounds)))
      (list start end
            (picard-completion--function-table)
            :annotation-function #'picard-completion--function-annotation
            :company-kind (lambda (_) 'function)
            :exclusive 'yes)))

   ;; ---- Variable / tag completion ----
   ((picard-completion--variable-bounds)
    (let* ((bounds (picard-completion--variable-bounds))
           (start  (car bounds))
           (end    (cdr bounds)))
      (list start end
            (picard-completion--tag-table)
            :annotation-function #'picard-completion--tag-annotation
            :company-kind (lambda (_) 'variable)
            ;; After accepting a candidate, append a closing `%' unless
            ;; one is already present at point.
            :exit-function
            (lambda (_candidate status)
              (when (eq status 'finished)
                (unless (eq (char-after) ?%)
                  (insert "%"))))
            :exclusive 'yes)))

   ;; ---- No completion context ----
   (t nil)))

;;;; Setup entry point

(defun picard-completion-setup ()
  "Register the Picard CAPF function in the current buffer.

Adds `picard-completion-at-point' to the buffer-local value of
`completion-at-point-functions'.

Call this from a major mode hook:

  (add-hook \\='picard-mode-hook #\\='picard-completion-setup)

The function is added at the front of the list so it takes priority over
generic completion sources while still allowing fallback when point is
not in a Picard-specific context (because `picard-completion-at-point'
returns nil in that case)."
  (add-hook 'completion-at-point-functions
            #'picard-completion-at-point nil t))

(provide 'picard-completion)
;;; picard-completion.el ends here
