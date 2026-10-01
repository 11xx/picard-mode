;;; picard-ts-mode.el --- Tree-sitter support for Picard Tagger Script -*- lexical-binding: t; -*-

;; Author: 11xx
;; Version: 2026.4.22
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages music musicbrainz picard tagger tree-sitter
;; URL: https://github.com/11xx/picard-mode

;;; Commentary:

;; This file provides a tree-sitter-based major mode for MusicBrainz
;; Picard Tagger Script: the scripting language embedded in MusicBrainz
;; Picard for manipulating file tags and metadata.
;;
;; It is the tree-sitter variant of `picard-mode', intended for use with
;; Emacs 29 or later, which ships the built-in `treesit.el' library.
;; Where `picard-mode' relies on regex-based font-lock and manual
;; indentation, this mode delegates those responsibilities to a compiled
;; Tree-sitter grammar named `taggerscript', obtaining accurate,
;; incremental syntax highlighting and structure-aware editing.
;;
;; Language overview
;; =========================================================================
;;
;; Picard Tagger Script is a small expression language with three
;; primary constructs:
;;
;;   Functions   $funcname(arg1,arg2,...)
;;   Variables   %varname%
;;   Escapes     \n  \t  \uXXXX
;;
;; Everything else is treated as literal text.  Noop blocks $noop(...)
;; serve as comments; they may contain nested parentheses.
;;
;; Tree-sitter grammar
;; =========================================================================
;;
;; The grammar is developed at
;; https://codeberg.org/useless-utils/tree-sitter-taggerscript
;;
;; Node types of interest:
;;
;;   source_file      top-level document node
;;   function_call    $funcname(...): children: function_name, argument*
;;   noop             $noop(...) comment block
;;   variable         %varname%: child: variable_name
;;   escape_sequence  \X or \uXXXX
;;   text             literal text content
;;   argument         one argument in a function call (may nest)
;;
;; Relationship to picard-mode
;; ==========================================================================
;;
;; When the `taggerscript' grammar is available at runtime,
;; `picard-ts-mode' registers itself as a transparent upgrade via
;; `major-mode-remap-alist'.  Buffers that would normally open in
;; `picard-mode' are silently redirected to `picard-ts-mode' without
;; any user action.  See the bottom of this file for the auto-remap
;; logic.
;;
;; Usage
;; ==========================================================================
;;
;; Install the taggerscript Tree-sitter grammar (once):
;;
;;   M-x treesit-install-language-grammar RET taggerscript RET
;;
;; Or set up automatic installation:
;;
;;   (add-to-list 'treesit-language-source-alist
;;                picard-ts-mode--grammar-source)
;;
;; Files with extensions .picard or .pts are associated automatically.

;;; Code:

(require 'treesit)
;; `picard-mode' may provide shared customisation variables (e.g.
;; `picard-indent-level').  The require is optional: if the non-ts
;; variant is not installed, this mode still functions correctly.
(require 'picard-mode nil 'noerror)
(require 'picard-core nil 'noerror)


;;;; Grammar Source
;; ==========================================================================

;; `treesit-language-source-alist' is the registry Tree-sitter uses to
;; locate (and optionally compile and install) grammars on demand.  Each
;; entry is of the form:
;;
;;   (LANGUAGE-SYMBOL . (URL &optional REVISION SOURCE-DIR CC C++))
;;
;; or the shorter two-element form used here:
;;
;;   (LANGUAGE-SYMBOL URL)
;;
;; `treesit-install-language-grammar' reads this alist and clones the
;; repository, runs the Tree-sitter CLI to produce a shared library
;; (libtree-sitter-LANGUAGE.so / .dylib / .dll), and installs it under
;; `treesit-extra-load-path' or the default user grammar directory.

(defvar picard-ts-mode--grammar-source
  '(taggerscript "https://codeberg.org/useless-utils/tree-sitter-taggerscript")
  "Source for the taggerscript tree-sitter grammar.
To be added to `treesit-language-source-alist' for automatic installation.
The value is a two-element list (LANGUAGE-SYMBOL URL) as consumed by
`treesit-install-language-grammar'.")

;; Register the grammar source immediately so that calling
;; `treesit-install-language-grammar' with the symbol `taggerscript' works
;; after this file is loaded, without requiring manual configuration.
(add-to-list 'treesit-language-source-alist picard-ts-mode--grammar-source)


;;;; Syntax Table
;; ==========================================================================

;; A syntax table informs Emacs of the syntactic roles of individual
;; characters: which are word constituents, which are string delimiters,
;; which are comment starters, etc.  Tree-sitter handles structural parsing,
;; but the syntax table is still consulted by many built-in commands
;; (forward-word, mark-sexp, electric pairs, …).

(defvar picard-ts-mode--syntax-table
  (let ((table (make-syntax-table)))
    ;; '%' is the variable delimiter in Picard Script (%varname%).
    ;; Since the same character serves as both opener and closer, it cannot
    ;; be classified as a true paired delimiter.  Marking it as a symbol
    ;; constituent keeps %varname% as a single navigable token for M-f / M-b.
    (modify-syntax-entry ?% "_" table)
    ;; '$' introduces function calls.  Treating it as a symbol constituent
    ;; means M-b / M-f will include it in word motion over function names.
    (modify-syntax-entry ?$ "_" table)
    ;; '\' is the escape character.
    (modify-syntax-entry ?\\ "\\" table)
    ;; Parentheses are function-argument delimiters.
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    ;; Commas separate arguments; treat as punctuation.
    (modify-syntax-entry ?, "." table)
    table)
  "Syntax table for `picard-ts-mode'.")


;;;; Font-Lock Rules
;; ==========================================================================

;; Tree-sitter font-lock in Emacs 29+ works through *queries* written in the
;; Tree-sitter S-expression pattern language, very similar to how
;; tree-sitter-highlight or nvim-treesitter queries are written.
;;
;; `treesit-font-lock-rules' is a macro-like function that compiles a flat
;; property-list of keyword/pattern pairs into a list of internal rule
;; objects understood by `treesit-font-lock-settings'.
;;
;; Key keyword arguments:
;;
;;   :language SYMBOL
;;       Which grammar the query patterns belong to.  Must match the symbol
;;       passed to `treesit-parser-create' (here `taggerscript').
;;
;;   :feature SYMBOL
;;       A logical name for this group of rules.  Features are referenced by
;;       `treesit-font-lock-feature-list' to implement progressive decoration
;;       levels (see below).  Users can toggle individual features via
;;       `treesit-font-lock-level' or `font-lock-feature-list'.
;;
;;   :override BOOLEAN-OR-STRATEGY
;;       Controls what happens when a node has already been fontified.
;;       nil (default): do not override existing face.
;;       t: always override.
;;       'prepend: prepend to existing face.
;;       'append: append to existing face.
;;       'keep: keep existing face, set only if unset.
;;
;; Query pattern syntax:
;;
;;   (node_type)                     matches any node of that type
;;   (node_type) @capture            captures the node under @capture
;;   (parent (child) @capture)       matches child inside parent
;;   (parent field: (child) @cap)    matches a named field `field'
;;   [pat1 pat2] @capture: alternation: matches either pattern
;;   "#match?" predicate             applies a regex guard (rarely needed here)
;;
;; Each @capture name must correspond to a face variable (or be mapped via
;; the optional :default-face argument, not used here).  The special prefix
;; @font-lock- is stripped and the remainder used to look up a standard face.

(defvar picard-ts-mode--font-lock-settings
  (treesit-font-lock-rules

   ;; Level 1: Comments
   ;; =========================================================================
   ;; `noop' nodes represent $noop(...) blocks, which are the comment
   ;; mechanism in Picard Tagger Script.  They are styled so that they
   ;; are immediately distinguishable from executable code even at the
   ;; lowest decoration level.
   ;;
   ;; The :feature is named `comment' following the convention used across
   ;; all built-in ts-modes (c-ts-mode, python-ts-mode, etc.).
   :language 'taggerscript
   :feature 'comment
   '((noop) @font-lock-comment-face)

   ;; Level 2: Keywords / Definitions
   ;; =========================================================================
   ;; Function names (the identifier between $ and the opening paren).
   ;; The query uses a *field access*: the grammar attaches the child
   ;; `function_name' to the `function_call' node under the named field
   ;; `name:'.  Specifying the field makes the query more precise and
   ;; avoids matching function_name nodes that might appear in other
   ;; positions (unlikely here, but good practice).
   ;;
   ;; The `$' sigil is an anonymous node within `function_call'.  It
   ;; receives distinctive styling to visually distinguish the call
   ;; prefix from the function name itself.
   :language 'taggerscript
   :feature 'function
   '((function_call "$" @font-lock-function-call-face)
     (function_call name: (function_name) @font-lock-function-name-face))

   ;; Level 2: Variables
   ;; =========================================================================
   ;; The `variable' node wraps the entire %varname% token.  Its child
   ;; `variable_name' holds the bare identifier.  Two captures are used:
   ;;
   ;;   both the bare identifier and the surrounding % signs receive
   ;;   the variable-name face, so the entire %varname% token is
   ;;   visually unified as a single syntactic unit.
   ;; The alternation [...] captures both the opening and closing percent
   ;; signs as anonymous string literals in the grammar.  Anonymous nodes
   ;; are matched by their literal text in double quotes.
   :language 'taggerscript
   :feature 'variable
   :override t
   '((variable (variable_name) @font-lock-variable-name-face)
     (variable "%" @font-lock-variable-name-face))

   ;; Level 3: Escape Sequences
   ;; =========================================================================
   ;; Escape sequences (\n, \t, \uXXXX) deserve their own feature so that
   ;; users who want a clean view can suppress escape highlighting without
   ;; affecting string or variable colours.
   :language 'taggerscript
   :feature 'escape-sequence
   :override t
   '((escape_sequence) @font-lock-escape-face)

   ;; Level 3: Delimiters
   ;; =========================================================================
   ;; Parentheses surrounding function arguments and commas separating them
   ;; are anonymous nodes in the grammar (matched by their literal text).
   ;; Applying bracket/delimiter faces helps readers track nesting depth.
   :language 'taggerscript
   :feature 'delimiter
   '((function_call "(" @font-lock-bracket-face)
     (function_call ")" @font-lock-bracket-face)
     (function_call "," @font-lock-delimiter-face))

   ;; Level 4: Text / String Content
   ;; =========================================================================
   ;; In Picard Script, any content that is not a function call, variable,
   ;; or escape sequence is raw text passed through verbatim.  This gets
   ;; the lowest priority decoration: it serves as the visual baseline,
   ;; distinctly rendered so that everything that looks like data rather
   ;; than code is immediately apparent.
   ;;
   ;; :override is set to `keep' rather than the default nil so that text
   ;; nodes that overlap with other features (e.g. text inside an argument
   ;; that also contains a variable) do not clobber earlier, higher-priority
   ;; highlights.
   :language 'taggerscript
   :feature 'string
   :override 'keep
   '((text) @font-lock-string-face
     (argument_text) @font-lock-string-face))

  "Tree-sitter font-lock settings for `picard-ts-mode'.
Compiled by `treesit-font-lock-rules' into the internal representation
expected by `treesit-font-lock-settings'.")


;;;; Font-Lock Feature List
;; ==========================================================================

;; `treesit-font-lock-feature-list' controls *progressive decoration*:
;; which features are enabled at each font-lock level (1-4, controlled by
;; `treesit-font-lock-level', default 3).
;;
;; The value is a list of lists.  Each inner list contains feature symbols
;; that are active at that decoration level AND ALL LEVELS ABOVE IT.  The
;; mapping is cumulative:
;;
;;   Level 1 → features in element [0]
;;   Level 2 → features in elements [0] and [1]
;;   Level 3 → features in elements [0], [1], and [2]
;;   Level 4 → all features
;;
;; Convention (followed here and by all built-in ts-modes):
;;   Level 1: comment, definition (always-on, minimum usability)
;;   Level 2: keyword, string, type (standard highlighting)
;;   Level 3: operator, bracket, misc (enhanced decoration)
;;   Level 4: everything else (maximum detail)

(defvar picard-ts-mode--font-lock-feature-list
  '(;;   Level 1: minimal: comments only
    (comment)
    ;;   Level 2: standard: function names and variable identifiers
    (function variable)
    ;;   Level 3: enhanced: escape sequences and structural delimiters
    (escape-sequence delimiter)
    ;;   Level 4: maximum: text/string content as lowest-priority decoration
    (string))
  "Feature list for `picard-ts-mode' progressive font-lock decoration.
Assigned to `treesit-font-lock-feature-list' in the mode setup.")


;;;; Indentation Rules
;; ==========================================================================

;; `treesit-simple-indent-rules' describes indentation as a list of
;; *rule triples* of the form:
;;
;;   (LANGUAGE . ((MATCHER ANCHOR OFFSET) ...))
;;
;; where:
;;
;;   MATCHER: a predicate function or a tree-sitter node type symbol
;;              (or list of symbols) that identifies which lines these rules
;;              apply to.  The predicate receives three arguments:
;;              NODE, PARENT, BOL (beginning-of-line position).
;;
;;   ANCHOR: a function that returns the column reference point.
;;              Common values from `treesit-simple-indent-presets':
;;                `parent-bol': beginning of line containing parent node
;;                `first-sibling': start of first sibling
;;                `prev-sibling': start of previous sibling
;;
;;   OFFSET: an integer (or variable) added to the anchor column.
;;              Positive values indent right; negative values indent left.
;;
;; The rule list is tried in order; the first matching rule wins.
;;
;; `treesit-simple-indent-presets' provides a library of ready-made matchers
;; and anchors.  The key ones used here:
;;
;;   no-node        MATCHER: matches when point is on an empty line
;;                  (the node at BOL is nil)
;;   parent-is SYM  MATCHER: matches when the parent node type = SYM
;;   node-is SYM    MATCHER: matches when the current node type = SYM
;;   parent-bol     ANCHOR: column of the start of the parent node's line
;;   prev-sibling   ANCHOR: column of the previous sibling's start

(defvar picard-ts-mode--indent-rules
  `((taggerscript

     ;; Closing parenthesis alignment
     ;; =========================================================================
     ;; When the cursor sits on a `)` that closes a function call, align
     ;; it with the column of the parent `function_call' node's first
     ;; character (i.e. the `$').  This produces:
     ;;
     ;;   $func(arg1,
     ;;         arg2
     ;;   )  <- back-aligned with $func
     ;;
     ;; `node-is' matches the current (innermost) node at BOL.
     ;; `parent-bol' returns the beginning-of-line position of the
     ;; parent, which for a `)` inside a function_call is the line
     ;; containing the opening `$funcname(`.
     ((node-is ")") parent-bol 0)

     ;; Argument indentation
     ;; =========================================================================
     ;;   $if(condition,
     ;;     value_if_true  <- indented one level
     ;;     value_if_false
     ;;   )
     ;;
     ;; `parent-is' matches lines whose syntactic parent is `argument'
     ;; or `function_call'.  Two rules cover both the direct argument
     ;; node and content nested within it.
     ((parent-is "argument") parent-bol ,tab-width)
     ((parent-is "function_call") parent-bol ,tab-width)

     ;; Noop / comment blocks
     ;; =========================================================================
     ;; Content inside $noop(...) is treated as a comment and receives
     ;; no additional indentation.  Because noop can contain arbitrary
     ;; text (including line breaks), aligning its content with the
     ;; parent start (offset 0) preserves the author's formatting.
     ((parent-is "noop") parent-bol 0)

     ;; Top-level fallback
     ;; ====================================================================
     ;; Any node at the top level (parent is source_file) starts at
     ;; column 0.
     ((parent-is "source_file") parent-bol 0)

     ;; Empty lines
     ;; ====================================================================
     ;; When there is no node at BOL (blank line), do not change
     ;; indentation from whatever the user last set.
     (no-node parent-bol 0)))

  "Indentation rules for `picard-ts-mode'.
Assigned to `treesit-simple-indent-rules'.  See the commentary above
each rule group for a description of the matcher/anchor/offset semantics.")


;;;; Defun Navigation
;; ==========================================================================

;; `treesit-defun-type-regexp' tells Emacs which node types count as
;; "defuns" (top-level structural units) for the purposes of
;; `beginning-of-defun' (C-M-a) and `end-of-defun' (C-M-e).
;;
;; In languages like C or Python the defun is a function definition.
;; In Picard Script, the closest analogue is a top-level `function_call'
;; node: navigating between $if(...), $set(...), $noop(...) etc. is the
;; primary structural movement.
;;
;; The value is a regexp matched against node type names.  Using the
;; exact string "function_call" (anchored implicitly by treesit internals)
;; ensures only function call nodes are treated as defuns.

(defvar picard-ts-mode--defun-type-regexp
  (rx (or "function_call" "noop"))
  "Regexp matching tree-sitter node types treated as defuns.
Used by `beginning-of-defun' and `end-of-defun' for structural navigation
in `picard-ts-mode'.  Matches both `function_call' and `noop' nodes so
that both executable calls and comment blocks are navigable units.")


;;;; Imenu Settings
;; ==========================================================================

;; `treesit-simple-imenu-settings' builds an Imenu index from tree-sitter
;; nodes, enabling M-x imenu (or the Imenu sidebar) to jump to named
;; structural units.
;;
;; Each element has the form:
;;
;;   (CATEGORY-NAME NODE-TYPE-REGEXP PREDICATE FUNCTION)
;;
;; where:
;;   CATEGORY-NAME: string label shown as the Imenu category header
;;   NODE-TYPE-REGEXP: regexp matching node types to index
;;   PREDICATE: optional function to further filter nodes (nil = none)
;;   FUNCTION: function to extract the display name from a node,
;;                      or nil to use the node's text directly
;;
;; Here, function_call nodes are indexed by extracting the text of their
;; `function_name' child.  A `treesit-node-child-by-field-name' call
;; retrieves the child and `treesit-node-text' converts it to a string.

(defun picard-ts-mode--imenu-name (node)
  "Return the display name for NODE in the Imenu index.
For `function_call' nodes this is the text of the `function_name' child
(e.g. \"if\" for a $if(...) call).  Returns nil if no name is found,
which causes the node to be skipped in the Imenu listing."
  (when-let* ((name-node (treesit-node-child-by-field-name node "name")))
    (treesit-node-text name-node t)))

(defvar picard-ts-mode--imenu-settings
  `(("Functions" "\\`function_call\\'" nil picard-ts-mode--imenu-name))
  "Imenu settings for `picard-ts-mode'.
Assigned to `treesit-simple-imenu-settings'.  Indexes `function_call'
nodes under the \"Functions\" category, using the function name as the
display label.")


;;;; Setup Function
;; ==========================================================================

;; All tree-sitter integration variables are buffer-local: they must be set
;; inside the mode body (or a function called from it) rather than at the
;; top level.  `picard-ts-mode--setup' gathers all such assignments and is
;; called from `picard-ts-mode' only when the grammar is available.

(defun picard-ts-mode--setup ()
  "Configure tree-sitter integration for `picard-ts-mode'.
Sets all `treesit-*' buffer-local variables and calls
`treesit-major-mode-setup' to activate them.

This function is called from `picard-ts-mode' only when
`treesit-ready-p' confirms that the `taggerscript' grammar is loaded.
It must not be called in any other context."

  ;; Font-lock
  ;; =========================================================================
  ;; `treesit-font-lock-settings' holds the compiled query objects produced
  ;; by `treesit-font-lock-rules'.  Assigning this variable (buffer-local)
  ;; tells the font-lock machinery which queries to run.
  (setq-local treesit-font-lock-settings
              picard-ts-mode--font-lock-settings)

  ;; `treesit-font-lock-feature-list' maps decoration levels to feature
  ;; symbols (see the commentary on the variable definition above).
  (setq-local treesit-font-lock-feature-list
              picard-ts-mode--font-lock-feature-list)

  ;; Indentation
  ;; =========================================================================
  ;; `treesit-simple-indent-rules' is a list of (LANGUAGE . RULE-LIST)
  ;; pairs.  The rules are used by `treesit-indent' (the function bound to
  ;; TAB and <return> in tree-sitter modes) to determine the correct column.
  (setq-local treesit-simple-indent-rules
              picard-ts-mode--indent-rules)

  ;; Use tabs (not spaces) for indentation, with a tab stop of 2 columns.
  ;; Picard Script is often edited inline in the Picard UI which renders
  ;; tabs as 2-space indents.
  (setq-local indent-tabs-mode t)
  (setq-local tab-width 2)

  ;; Defun navigation
  ;; =========================================================================
  (setq-local treesit-defun-type-regexp
              picard-ts-mode--defun-type-regexp)

  ;; Imenu
  ;; =========================================================================
  (setq-local treesit-simple-imenu-settings
              picard-ts-mode--imenu-settings)

  ;; Comment syntax
  ;; =========================================================================
  ;; Picard Script has no line-comment syntax.  The $noop(...) block is the
  ;; closest equivalent, but it cannot be inserted with comment-dwim
  ;; directly.  Setting these variables to meaningful values allows
  ;; comment-related commands to work in a limited capacity and also tells
  ;; fill-paragraph how to handle comment regions.
  (setq-local comment-start "$noop(")
  (setq-local comment-end ")")
  (setq-local comment-start-skip (rx "$noop("))

  ;; Activate tree-sitter
  ;; =========================================================================
  ;; `treesit-major-mode-setup' is the final step.  It reads all the
  ;; `treesit-*' buffer-local variables set above and wires them into
  ;; Emacs's font-lock, indentation, navigation, and Imenu subsystems.
  ;; It also activates the tree-sitter parser created in the mode body.
  (treesit-major-mode-setup))


;;;; Mode Definition
;; ==========================================================================

;;;###autoload
(define-derived-mode picard-ts-mode prog-mode "Picard[ts]"
  "Major mode for editing MusicBrainz Picard Tagger Script (tree-sitter).

This mode uses the `treesit.el' API introduced in Emacs 29 and requires
the `taggerscript' Tree-sitter grammar to be installed.  When the grammar
is unavailable, the mode still activates but without syntax highlighting
or structure-aware indentation.

To install the grammar interactively:
  M-x treesit-install-language-grammar RET taggerscript RET

The grammar source URL is stored in `picard-ts-mode--grammar-source'
and is automatically added to `treesit-language-source-alist' when this
file is loaded.

Keyboard bindings inherited from `prog-mode':
  \\[beginning-of-defun]: move to start of enclosing function call
  \\[end-of-defun]: move to end of enclosing function call
  \\[indent-for-tab-command]: indent current line via tree-sitter rules

\\{picard-ts-mode-map}"
  :syntax-table picard-ts-mode--syntax-table

  ;; `treesit-ready-p' checks two things:
  ;;   1. The `treesit' module is available (Emacs was built with it).
  ;;   2. The `taggerscript' grammar shared library can be found and loaded.
  ;;
  ;; Passing nil as the second argument means: emit a warning in the echo
  ;; area if the grammar is missing, but do not signal an error.  This
  ;; allows the mode to activate (providing basic prog-mode behaviour) even
  ;; without the grammar, which is preferable to a hard failure.
  (when (treesit-ready-p 'taggerscript)
    ;; `treesit-parser-create' allocates a Tree-sitter parser for the named
    ;; language and associates it with the current buffer.  The parser is
    ;; incremental: it re-parses only the changed region of the buffer after
    ;; each edit, keeping the syntax tree up to date efficiently.
    (treesit-parser-create 'taggerscript)
    ;; Delegate all treesit variable setup to the dedicated function.
    (picard-ts-mode--setup)))

;; Show combined Eldoc help for the thing at point.
(define-key picard-ts-mode-map (kbd "C-c C-d") #'picard-eldoc-show-all)


;;;; Auto-mode Association
;; ==========================================================================

;; Associate file extensions with this mode.  The `auto-mode-alist' entries
;; ensure that .picard and .pts files open in `picard-ts-mode' (or fall back
;; gracefully; see `major-mode-remap-alist' below).

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.picard\\'" . picard-ts-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.pts\\'" . picard-ts-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ptsp\\'" . picard-ts-mode))


;;;; Transparent Upgrade via major-mode-remap-alist
;; ==========================================================================

;; `major-mode-remap-alist' (introduced in Emacs 29) allows a mode to
;; transparently redirect buffers that would open in one major mode to
;; another.  This is the canonical mechanism for ts-modes to upgrade their
;; regex-based predecessors without users needing to update their
;; `auto-mode-alist' or `find-file' hooks.
;;
;; The check `(treesit-ready-p 'taggerscript t)' uses t as the second
;; argument (QUIET), suppressing any warning.  The remap is added only
;; when the grammar is actually available, so that users without the grammar
;; continue to get `picard-mode' as before.
;;
;; Result: if the taggerscript grammar is installed, any buffer that Emacs
;; would open in `picard-mode' is silently redirected to `picard-ts-mode'.

;;;###autoload
(when (and (fboundp 'treesit-ready-p)
           (treesit-ready-p 'taggerscript t))
  (add-to-list 'major-mode-remap-alist '(picard-mode . picard-ts-mode)))


;;;; Grammar Installation Helper
;; ==========================================================================

(defun picard-ts-mode-install-grammar ()
  "Install the taggerscript Tree-sitter grammar for `picard-ts-mode'.
This is a convenience wrapper around `treesit-install-language-grammar'.
The grammar source URL must already be present in
`treesit-language-source-alist', which is ensured by loading this file.

After successful installation, revert any buffers visiting Picard Script
files to activate tree-sitter highlighting."
  (interactive)
  (unless (assq 'taggerscript treesit-language-source-alist)
    (add-to-list 'treesit-language-source-alist
                 picard-ts-mode--grammar-source))
  (treesit-install-language-grammar 'taggerscript)
  (message "taggerscript grammar installed.  \
Revert Picard Script buffers to activate tree-sitter mode."))


;;;; Optional Feature Integration
;; ==========================================================================

;; Same extras pattern as picard-mode: load flymake, eldoc, and completion
;; when available.

(defun picard-ts-mode--setup-extras ()
  "Activate optional flymake, eldoc, and completion features."
  (picard--setup-optional-features))

(add-hook 'picard-ts-mode-hook #'picard-ts-mode--setup-extras)

(add-hook 'picard-ts-mode-hook #'picard--setup-builtin-variables)


;;;; Provide
;; ==========================================================================

(provide 'picard-ts-mode)

;;; picard-ts-mode.el ends here
