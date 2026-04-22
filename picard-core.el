;;; picard-core.el --- Shared code for Picard Tagger Script support  -*- lexical-binding: t; -*-

;; Author: 11xx
;; Version: 2026.4.22
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, picard, musicbrainz
;; URL: https://codeberg.org/useless-utils/picard-mode

(require 'cl-lib)
(require 'picard-data nil 'noerror)

;;;; Builtin Variable Highlighting
;; ==========================================================================

;; Picard variables are wrapped in % delimiters (%artist%, %_filename%, etc.).
;; The base font-lock pass applies a uniform face to all of them.  This
;; section adds a second layer that distinguishes:
;;
;;   - Well-known read/write tags (e.g. %artist%, %title%)
;;     receive distinctive highlighting to set them apart.
;;
;;   - Hidden read-only internal variables (e.g. %_filename%, %_bitrate%)
;;     receive a different style to indicate they are internal.
;;
;; Tags not present in `picard-builtin-tags' retain the base face,
;; clearly marking them as user-defined variables.

(defun picard--add-builtin-variable-keywords ()
  "Register font-lock rules that highlight known Picard builtin tag variables.

Requires `picard-data'.  When available, partitions the full tag list into
visible tags (no leading underscore) and hidden internal variables (leading
underscore), then adds keyword patterns to the current buffer that apply
distinct styling to each group, overriding any face already applied.

Visible builtin tags  → one style
Hidden internal vars → another style

Intended to be called from a major-mode hook, not interactively."
  (let* ((all-tags   (picard-tag-names))
         (visible    (cl-remove-if
                      (lambda (s) (string-prefix-p "_" s))
                      all-tags))
         (hidden     (cl-remove-if-not
                      (lambda (s) (string-prefix-p "_" s))
                      all-tags))
         (builtin-re (concat "%" (regexp-opt visible) "%"))
         (hidden-re  (concat "%" (regexp-opt hidden)  "%")))
    (font-lock-add-keywords
     nil
     `((,builtin-re (0 'font-lock-constant-face t))
       (,hidden-re  (0 'font-lock-type-face     t)))
     'append)))

(defun picard-mode--setup-builtin-variables ()
  "Highlight known Picard builtin tag variables in `picard-mode' buffers.
Delegates to `picard--add-builtin-variable-keywords'."
  (picard--add-builtin-variable-keywords))

(defun picard-ts-mode--setup-builtin-variables ()
  "Highlight known Picard builtin tag variables in `picard-ts-mode' buffers.
Delegates to `picard--add-builtin-variable-keywords'."
  (picard--add-builtin-variable-keywords))

(defun picard--setup-builtin-variables ()
  "Highlight known Picard builtin tag variables in the current buffer."
  (picard--add-builtin-variable-keywords))

(defun picard--setup-eldoc ()
  "Load Picard Eldoc support and enable `eldoc-mode' in the current buffer."
  (when (require 'picard-eldoc nil t)
    (picard-eldoc-setup)
    (eldoc-mode 1)))

(defun picard--setup-optional-features ()
  "Enable optional Picard features in the current buffer."
  (when (require 'picard-flymake nil t)
    (picard-flymake-setup)
    (flymake-mode 1))
  (picard--setup-eldoc)
  (when (require 'picard-completion nil t)
    (picard-completion-setup)))

(provide 'picard-core)
;;; picard-core.el ends here
