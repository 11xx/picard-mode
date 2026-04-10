;;; picard-mode.el --- MusicBrainz Picard Tagger Script mode -*- lexical-binding: t; -*-

;; Author: 11xx
;; Version: 2026.4.10
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, musicbrainz, picard, tagger
;; URL: https://codeberg.org/useless-utils/picard-mode

;;; Commentary:

;; This package provides a major mode for editing MusicBrainz Picard Tagger
;; Script files.  Picard Tagger Script is used to define file renaming
;; patterns and other transformations within the MusicBrainz Picard audio
;; file tagger.
;;
;; Language grammar (from the official Picard parser source):
;;
;;   unicodechar ::= '\u' [a-fA-F0-9]{4}
;;   text        ::= [^$%] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
;;   argtext     ::= [^$%(),] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
;;   identifier  ::= [a-zA-Z0-9_]
;;   variable    ::= '%' (identifier | ':')+ '%'
;;   function    ::= '$' (identifier)+ '(' (argument (',' argument)*)? ')'
;;   expression  ::= (variable | function | text)*
;;   argument    ::= (variable | function | argtext)*
;;
;; Special characters:
;;   $       : starts a function call
;;   %...%   : wraps a variable reference
;;   \       : escape character (\$, \%, \(, \), \,, \\, \n, \t, \uXXXX)
;;
;; The special function $noop(...) serves as the comment mechanism.
;; Everything inside $noop(), including nested function calls, is ignored
;; by the Picard runtime.  This mode treats $noop(...) as a block comment
;; using syntax-propertize-function to correctly handle nested parentheses.
;;
;; File extensions recognized: .picard, .pts
;;
;; Installation:
;;   (require 'picard-mode)
;;
;; Or with use-package:
;;   (use-package picard-mode)

;;; Code:

;;;; Dependencies
;; ==========================================================================

(require 'syntax)   ; For syntax-propertize machinery
(require 'picard-core)

;;;; Customization Group
;; ==========================================================================

(defgroup picard nil
  "Major mode for MusicBrainz Picard Tagger Script files."
  :group 'languages
  :prefix "picard-"
  :link '(url-link "https://codeberg.org/useless-utils/picard-mode"))

(defcustom picard-tab-width 2
  "Number of spaces each tab represents in `picard-mode' indentation.

Picard scripts use tab-only indentation.  This value controls how many
visual columns a single tab character occupies, which affects only display
width: the actual indentation token is always a literal TAB character."
  :type 'integer
  :group 'picard)

;;;; Syntax Table
;; ==========================================================================

;; Design note on syntax-table entries:
;;
;; Picard has no line-comment character (no # comments).  The only comment
;; form is $noop(...), a multi-line block comment whose boundaries are
;; detected at runtime via syntax-propertize-function (see below).
;; Therefore the syntax table is kept minimal: it defines character classes
;; that help Emacs navigate the structure of the language without
;; accidentally treating ordinary text as comments or string delimiters.

(defvar picard-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Parentheses: Picard function arguments are wrapped in ( ... ).
    ;; Assigning open/close paren syntax enables sexp-navigation commands
    ;; (forward-sexp, backward-sexp, show-paren-mode, etc.) to work on
    ;; function argument lists.
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)

    ;; Backslash as escape character.
    ;; Picard supports \$, \%, \(, \), \,, \\, \n, \t, and \uXXXX.
    ;; Marking \ as an escape character lets Emacs skip over two-character
    ;; escape sequences during navigation and avoids misinterpreting
    ;; \( or \) as unbalanced parentheses.
    (modify-syntax-entry ?\\ "\\" table)

    ;; Dollar sign: prefix/symbol constituent.
    ;; $ is the function-call sigil.  Treating it as a symbol constituent
    ;; means that $funcname forms a single symbol token, which simplifies
    ;; font-lock regexes and sexp navigation.
    (modify-syntax-entry ?$ "_" table)

    ;; Percent sign: symbol constituent.
    ;; % is the variable delimiter.  Like $, treating it as a symbol
    ;; constituent keeps %varname% in a single navigable unit.
    (modify-syntax-entry ?% "_" table)

    ;; Comma: punctuation.
    ;; In Picard, commas separate function arguments.  Marking them as
    ;; punctuation (rather than whitespace or symbol) provides correct
    ;; word-boundary behavior.
    (modify-syntax-entry ?, "." table)

    ;; Underscore and colon: word/symbol constituents.
    ;; Variable names may contain colons (e.g., %musicbrainz_trackid%).
    ;; Underscores are already word/symbol constituents by default in most
    ;; syntax tables, but colon needs explicit promotion.
    (modify-syntax-entry ?: "_" table)

    ;; Double quote: punctuation, not a string delimiter.
    ;; Picard does not use prog-style string syntax, so treating " as
    ;; punctuation prevents Emacs from entering string state and incorrectly
    ;; spanning text between quotes.
    (modify-syntax-entry ?\" "." table)

    table)
  "Syntax table for `picard-mode'.

Designed around the Picard grammar: parentheses delimit function arguments,
backslash is the escape character, and $ / % are symbol constituents rather
than special characters.  No comment syntax is assigned here: comment
regions are established dynamically by `picard--syntax-propertize' using
text properties, which correctly handles the nested-parenthesis structure
of $noop(...) blocks.")

;;;; Font-Lock Keywords
;; ==========================================================================

;; Design notes on font-lock choices:
;;
;; 1. Function names ($func): matched with font-lock-function-name-face.
;;    The regex deliberately excludes $noop: noop blocks are handled as
;;    comments by syntax-propertize, not as highlighted function calls.
;;    Using a negative lookahead (?!noop) keeps font-lock and syntax
;;    properties consistent: if Emacs already marks a region as a comment,
;;    font-lock would ignore it anyway, but the exclusion also avoids
;;    "$noop" appearing briefly in a non-comment face during re-fontification.
;;
;; 2. Variables (%var%): matched with font-lock-variable-name-face.
;;    Variable names may contain colons (:) in addition to alphanumerics
;;    and underscores, per the grammar.
;;
;; 3. Escape sequences (\X and \uXXXX): matched with font-lock-escape-face.
;;    This highlights the escape sequences that Picard itself interprets,
;;    giving a visual cue that these are not literal characters.
;;
;; 4. Commas: matched with font-lock-delimiter-face (Emacs 29+).
;;    A fallback to font-lock-comment-delimiter-face is provided for
;;    compatibility with Emacs versions that lack font-lock-delimiter-face.
;;
;; 5. $noop itself: NOT handled here.  It is rendered as a comment region
;;    by syntax-propertize, so font-lock will apply font-lock-comment-face
;;    automatically without any explicit keyword entry.

(defvar picard--font-lock-delimiter-face
  ;; font-lock-delimiter-face was introduced in Emacs 29.1.
  ;; Fall back gracefully on older Emacsen.
  (if (facep 'font-lock-delimiter-face)
      'font-lock-delimiter-face
    'font-lock-comment-delimiter-face)
  "Face used to highlight argument-separator commas in Picard scripts.

On Emacs 29.1 and later, this resolves to `font-lock-delimiter-face'.
On earlier versions, it falls back to `font-lock-comment-delimiter-face'.")

(defconst picard-font-lock-keywords
  `(
    ;; Escape sequences
    ;; ====================================================================
    ;; Must come first so that \$ and \% are highlighted as escapes and not
    ;; as the start of a function call or variable reference.
    ;; Matches: \n \t \\ \$ \% \( \) \, and \uXXXX (Unicode escapes)
    (,(rx (or (seq "\\" (any "nts$%()\\,"))
              (seq "\\u" (repeat 4 (any hex-digit)))))
     (0 'font-lock-escape-face))

    ;; Function names ($funcname)
    ;; ====================================================================
    ;; Matches $identifier but not $noop.  The regex matches any $-prefixed
    ;; name; the `when' guard then suppresses highlighting when the match is
    ;; exactly "$noop" (using string-equal for an exact match, not a prefix
    ;; match, so hypothetical functions named $noopXYZ are not excluded).
    ;;
    ;; Highlight only the sigil + name, not the opening parenthesis,
    ;; so that the paren retains its structural syntax-class coloring.
    (,(rx "$" (not (any space)) (zero-or-more (any alnum "_")))
     (0 (when (not (string-equal (match-string 0) "$noop"))
          'font-lock-function-name-face)))

    ;; Variable references (%varname%)
    ;; ====================================================================
    ;; Per the grammar: identifier  ::= [a-zA-Z0-9_]
    ;;                  variable    ::= '%' (identifier | ':')+ '%'
    ;; The colon is also permitted (used in some special variables).
    (,(rx "%" (one-or-more (any alnum "_:")) "%")
     (0 'font-lock-variable-name-face))

    ;; Argument-separator commas
    ;; ====================================================================
    ;; Commas that are not escaped (\, is a literal comma in Picard output).
    ;; The escape sequence rule above already claims \, matches, so only bare
    ;; commas remain for this pattern.  A simple one-character match suffices.
    ("," (0 picard--font-lock-delimiter-face))

    ;; $noop opening sigil
    ;; ====================================================================
    ;; Opening of comment function.
    (,(rx "$noop")
     (0 'font-lock-comment-face prepend)))
  "Font-lock keyword specification for `picard-mode'.

Entries are ordered so that escape sequences take priority over function-call
and variable-reference patterns, preventing \\$ and \\% from being
misidentified.")

;;;; Syntax Propertize: $noop Comment Detection
;; ==========================================================================

;; Design rationale for syntax-propertize-function:
;;
;; Picard's only comment form is $noop(...), which may span multiple lines
;; and may contain arbitrarily nested parentheses and function calls.  A
;; regex-based comment syntax (comment-start-re) cannot handle nested
;; delimiters, so this mode uses the syntax-propertize mechanism instead.
;;
;; The approach:
;;   1. Scan forward in the requested region for "$noop(".
;;   2. On each match, manually walk forward, tracking parenthesis depth.
;;      Backslash escapes are honoured so that \( and \) inside a noop
;;      do not disturb the depth count.
;;   3. When depth returns to zero, the matching ) has been found.
;;   4. Apply text-property 'syntax-table to mark:
;;        • The "$" of "$noop(" as generic comment-start (syntax code 11,
;;          style "b" = block comment fence).
;;        • The closing ")" as generic comment-end  (syntax code 12,
;;          style "b").
;;
;; Syntax codes 11 and 12 are the "comment fence" codes that Emacs uses for
;; non-standard comment delimiters.  When a character carries syntax code 11
;; via a text property, Emacs treats everything from that point to the next
;; syntax-code-12 character as a comment.  This integrates cleanly with
;; font-lock (which respects comment regions) and with Emacs' comment
;; navigation commands.
;;
;; The cons cell '(11 . ?!) is the canonical way to specify a comment-start
;; fence: 11 is the integer syntax code for "comment start (style b)", and
;; ?! is an arbitrary paired-comment character (required by the data
;; structure but not functionally significant for fence-style comments).
;; Similarly '(12 . ?!) marks a comment-end fence.

(defun picard--syntax-propertize (start end)
  "Apply syntax properties for $noop() comment blocks between START and END.

Scans forward from START looking for occurrences of the literal string
\"$noop(\".  For each occurrence, walks forward counting parenthesis depth
(honoring backslash escapes) to locate the matching closing parenthesis.
Marks the \"$\" of \"$noop\" with comment-start-fence syntax (code 11) and
the closing \")\" with comment-end-fence syntax (code 12) using
`put-text-property' with the `syntax-table' property.

This function is assigned to `syntax-propertize-function' in `picard-mode'.
It is called by the Emacs font-lock and syntax-analysis machinery whenever
a buffer region needs its syntax properties refreshed (e.g., after edits)."
  (goto-char start)
  (while (re-search-forward "\\$noop(" end t)
    (let* (;; noop-start: position of the '$' that begins "$noop("
           (noop-start (match-beginning 0))
           ;; paren-open: position of the '(' that opens the argument list.
           ;; (1- (point)) because `re-search-forward' leaves point AFTER the
           ;; matched string, so point is one past the '('.
           (_paren-open (1- (point)))
           ;; depth: tracks how many unmatched '(' have been seen.
           ;; Starts at 1 because we have already consumed the opening '('.
           (depth 1))
      ;; Mark the '$' as a comment-start fence.
      ;; Everything from here to the matching ')' will be in comment syntax.
      (put-text-property noop-start (1+ noop-start)
                         'syntax-table '(11 . ?!))
      ;; Walk forward, adjusting depth for each unescaped ( or ).
      ;; The loop terminates when depth reaches 0 (matching ')' found)
      ;; or when the scan reaches END (noop block continues beyond region).
      (while (and (> depth 0) (< (point) end))
        (let ((ch (char-after)))
          (cond
           ;; Backslash escape: skip both the backslash and the next
           ;; character.  This prevents \( and \) inside a noop from
           ;; being counted as depth changes.
           ((eq ch ?\\)
            (forward-char 2))
           ;; Opening paren: increase nesting depth.
           ((eq ch ?\()
            (setq depth (1+ depth))
            (forward-char 1))
           ;; Closing paren: decrease depth.  When depth reaches zero,
           ;; this ')' is the one that closes the $noop block.
           ((eq ch ?\))
            (setq depth (1- depth))
            (when (zerop depth)
              ;; Mark this ')' as a comment-end fence.
              (put-text-property (point) (1+ (point))
                                 'syntax-table '(12 . ?!)))
            (forward-char 1))
           ;; Any other character: just advance.
           (t
            (forward-char 1))))))))

;;;; Indentation
;; ==========================================================================

;; Design rationale for indentation:
;;
;; Picard scripts are typically written as single-expression programs or
;; short multi-line pipelines.  There is no standard indentation convention
;; published by the Picard project, so this mode adopts the pragmatic rule:
;;
;;   • Each nesting level adds one TAB.
;;   • Nesting level is determined by counting the net open parentheses on
;;     all preceding non-empty lines (open parens minus close parens).
;;
;; Tab-only indentation is enforced because:
;;   a) Picard scripts are line-oriented tag data.  Accidental leading spaces
;;      could corrupt output if the script is used in a context where leading
;;      whitespace is significant.
;;   b) Using tabs preserves visual flexibility (users can configure tab-width
;;      without touching the file).
;;
;; `electric-indent-mode' is disabled locally because it inserts spaces after
;; certain characters, which is undesirable for the reasons above.

(defun picard--count-net-parens (text)
  "Return the net open-parenthesis count in TEXT.

Counts unescaped '(' as +1 and unescaped ')' as -1.  Escaped parentheses
(\\( and \\)) are skipped.  The return value is the sum across all
characters in TEXT and may be negative if there are more close parens than
open parens."
  (let ((count 0)
        (i 0)
        (len (length text)))
    (while (< i len)
      (let ((ch (aref text i)))
        (cond
         ;; Skip backslash + next character (escape sequence).
         ((eq ch ?\\)
          (setq i (+ i 2)))
         ((eq ch ?\()
          (setq count (1+ count))
          (setq i (1+ i)))
         ((eq ch ?\))
          (setq count (1- count))
          (setq i (1+ i)))
         (t
          (setq i (1+ i))))))
    count))

(defun picard-indent-line ()
  "Indent the current line in a Picard Tagger Script buffer.

Computes the indentation level by summing net open parentheses across all
preceding non-empty lines, then indents the current line with that many
TAB characters.  Indentation level is clamped to a minimum of zero.

This function is assigned to `indent-line-function' in `picard-mode'."
  (interactive)
  (let ((indent-level 0))
    ;; Walk backwards through preceding non-empty lines summing net parens.
    (save-excursion
      (beginning-of-line)
      (let ((limit (point)))
        (goto-char (point-min))
        (while (< (point) limit)
          (let ((line-text (buffer-substring-no-properties
                            (line-beginning-position)
                            (line-end-position))))
            (unless (string-blank-p line-text)
              (setq indent-level
                    (+ indent-level (picard--count-net-parens line-text)))))
          (forward-line 1))))
    ;; Clamp to non-negative.
    (setq indent-level (max 0 indent-level))
    ;; Apply indentation: delete existing leading whitespace and insert tabs.
    (save-excursion
      (beginning-of-line)
      (delete-horizontal-space)
      (insert (make-string indent-level ?\t)))
    ;; If point is within the leading whitespace, move it past the indent.
    (when (< (current-column) indent-level)
      (beginning-of-line)
      (forward-char indent-level))))

;;;; Keymap
;; ==========================================================================

(defvar picard-mode-map
  (let ((map (make-sparse-keymap)))
    ;; The keymap is intentionally sparse.  Standard Emacs commands for
    ;; navigation (forward-sexp, backward-sexp), commenting (comment-dwim),
    ;; and indentation (TAB) work via the mode's syntax table, indentation
    ;; function, and comment variables without requiring custom bindings.
    ;;
    ;; Mode-specific bindings may be added here as the mode evolves.
    map)
  "Keymap for `picard-mode'.

Inherits all standard Emacs bindings.  Navigation, comment insertion, and
indentation are handled through the mode's syntax table, `comment-dwim',
and `picard-indent-line' respectively.")

;; Show combined Eldoc help for the thing at point.
(define-key picard-mode-map (kbd "C-c C-d") #'picard-eldoc-show-all)

;;;; Mode Definition
;; ==========================================================================

;;;###autoload
(define-derived-mode picard-mode prog-mode "Picard"
  "Major mode for editing MusicBrainz Picard Tagger Script files.

Picard Tagger Script is used within the MusicBrainz Picard audio tagger
to define file renaming patterns and tag transformations.

Syntax overview:
  $function(arg1,arg2)  : function call
  %variable%            : variable reference
  $noop(comment text)   : comment (everything inside is ignored)
  \\$  \\%  \\(  \\)    : escaped special characters

Indentation uses TAB characters only (never spaces).  Each nesting level
inside parentheses adds one TAB.  `electric-indent-mode' is disabled
locally to prevent accidental space insertion.

See also: `picard-tab-width', `picard-indent-line'."

  ;; Syntax table
  ;; =========================================================================
  ;; `define-derived-mode' automatically installs the table named
  ;; `picard-mode-syntax-table' (defined above) as the buffer-local syntax
  ;; table.

  ;; Font-lock
  ;; =========================================================================
  (setq-local font-lock-defaults
              '(picard-font-lock-keywords
                nil   ; KEYWORDS-ONLY: nil means syntactic fontification
                                        ;   (strings, comments) is also performed, which is
                                        ;   needed to render $noop blocks as comments.
                nil   ; CASE-FOLD: nil means case-sensitive matching.
                nil   ; SYNTAX-ALIST: no additional syntax modifications.
                nil)) ; SYNTAX-BEGIN: nil = use font-lock defaults.

  ;; Syntax propertize
  ;; =========================================================================
  ;; Assign the $noop-detection function.  Emacs calls this before each
  ;; font-lock pass over a region, ensuring comment properties are up to
  ;; date before the font engine runs.
  (setq-local syntax-propertize-function #'picard--syntax-propertize)

  ;; Indentation
  ;; =========================================================================
  (setq-local indent-line-function #'picard-indent-line)
  ;; Tab-only indentation: tabs are inserted, never spaces.
  (setq-local indent-tabs-mode t)
  (setq-local tab-width picard-tab-width)
  ;; Disable electric-indent-mode locally.  This mode inserts spaces
  ;; automatically after certain characters (e.g., after a closing paren),
  ;; which would produce mixed tab/space indentation and potentially corrupt
  ;; Picard output strings.
  (electric-indent-local-mode -1)

  ;; Comment configuration
  ;; =========================================================================
  ;; These variables teach Emacs' universal comment commands (comment-dwim,
  ;; comment-region, uncomment-region) about Picard's comment syntax.
  ;;
  ;; comment-start and comment-end define the delimiters used when Emacs
  ;; inserts new comments (e.g., via M-;).
  ;;
  ;; comment-start-skip is the regex Emacs uses to find the beginning of an
  ;; existing comment when stripping or navigating.  It must match "$noop("
  ;; possibly preceded by whitespace.
  (setq-local comment-start "$noop(")
  (setq-local comment-end ")")
  (setq-local comment-start-skip "\\$noop(\\s-*")
  ;; Block comment aliases mirror the single-form variables since Picard has
  ;; only one comment form ($noop is inherently a block comment).
  (setq-local block-comment-start "$noop(")
  (setq-local block-comment-end ")")
  ;; Padding: do not add a space between the delimiter and the comment text,
  ;; since "$noop( text )" with spaces is valid but "$noop(text)" is the
  ;; idiomatic form.
  (setq-local comment-padding "")

  ;; Parse-sexp integration
  ;; =========================================================================
  ;; Inform parse-sexp that comments exist and that it should use the
  ;; syntax-table text properties set by picard--syntax-propertize.
  (setq-local parse-sexp-ignore-comments t)
  (setq-local parse-sexp-lookup-properties t))

;;;; Auto-mode-alist Registration
;; ==========================================================================

;; Associate file extensions .picard and .pts with picard-mode.
;;
;; .picard: the conventional extension for standalone Picard script files.
;; .pts: short for "Picard Tagger Script", sometimes used in the
;;           community for script files shared outside the Picard GUI.
;;
;; The ###autoload cookie ensures these associations are registered without
;; fully loading the package (via autoload files), consistent with standard
;; Emacs package conventions.

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.picard\\'" . picard-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.pts\\'" . picard-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ptsp\\'" . picard-mode))


;;;; Optional Feature Integration
;; ==========================================================================

;; Load flymake, eldoc, and completion support when the corresponding
;; packages are available.  Each feature file provides a `-setup' function
;; that registers the appropriate hook.  Failures are silently ignored so
;; the base mode always works even without the extra packages.

(defun picard-mode--setup-extras ()
  "Activate optional flymake, eldoc, and completion features.

Called from `picard-mode-hook'.  Each feature is loaded lazily:
if the corresponding file is absent, that feature is simply skipped."
  (picard--setup-optional-features))

(add-hook 'picard-mode-hook #'picard-mode--setup-extras)

(add-hook 'picard-mode-hook #'picard--setup-builtin-variables)


;;;; Provide
;; ==========================================================================

(provide 'picard-mode)

;;; picard-mode.el ends here
