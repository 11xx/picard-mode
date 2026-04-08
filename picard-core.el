(require 'picard-data nil 'noerror)

;;;; ─── Builtin Variable Highlighting ──────────────────────────────────────────

;; Picard variables are wrapped in % delimiters (%artist%, %_filename%, etc.).
;; The base font-lock pass applies `font-lock-variable-name-face' to all of
;; them uniformly.  This section adds a second layer that distinguishes:
;;
;;   - Well-known read/write tags (e.g. %artist%, %title%)
;;     highlighted with `font-lock-constant-face'.
;;
;;   - Hidden read-only internal variables (e.g. %_filename%, %_bitrate%)
;;     highlighted with `font-lock-type-face'.
;;
;; Tags not present in `picard-builtin-tags' remain as
;; `font-lock-variable-name-face', clearly marking user-defined variables.

(defun picard--add-builtin-variable-keywords ()
  "Register font-lock rules that highlight known Picard builtin tag variables.

Requires `picard-data'.  When available, partitions the full tag list into
visible tags (no leading underscore) and hidden internal variables (leading
underscore), then adds keyword patterns to the current buffer that apply
distinct faces to each group, overriding any face already applied.

Visible builtin tags  → `font-lock-constant-face'
Hidden internal vars  → `font-lock-type-face'

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

(provide 'picard-core)
;;; picard-core.el ends here
