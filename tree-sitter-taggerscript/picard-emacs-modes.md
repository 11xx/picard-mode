# Picard Tagger Script: Emacs Mode Development — From Traditional to Tree-sitter

---

## Executive Summary

This document describes the design and implementation of two Emacs major modes for [MusicBrainz Picard Tagger Script](https://picard-docs.musicbrainz.org/v2.9/en/extending/scripting.html): a traditional regex-and-syntax-table mode (`picard-mode.el`) and a tree-sitter-powered successor (`picard-ts-mode.el`). Together with the companion tree-sitter grammar (`tree-sitter-taggerscript/grammar.js` and `src/scanner.c`), they form a complete editing environment for a language whose single most interesting parsing challenge—the nested-parenthesis comment construct `$noop(...)`—sits at the intersection of Emacs syntax machinery and formal parser theory.

The traditional mode teaches the reader how Emacs constructs a picture of a buffer's syntax through three interlocking mechanisms: the **syntax table** (static character classification), **font-lock** (regex-driven highlighting), and **`syntax-propertize-function`** (dynamic, position-specific syntax overrides). The tree-sitter mode replaces those mechanisms with a compiled incremental parser, S-expression query patterns, and a declarative indentation rule language. Both modes share the same public interface: identical file-extension associations, the same `comment-start`/`comment-end` variables, and a transparent upgrade path so that installing the grammar silently activates the better mode.

---

## The Target Language

### Syntax of Picard Tagger Script

[Picard Tagger Script](https://picard-docs.musicbrainz.org/v2.9/en/extending/scripting.html) is the expression language embedded in [MusicBrainz Picard](https://github.com/metabrainz/picard/blob/master/picard/script/parser.py), the open-source audio file tagger. It is used to construct file-renaming patterns and metadata transformations: a script is evaluated to a string, and that string becomes a file name, a tag value, or a sort key.

The language has three structural elements:

- **Functions** — `$funcname(arg1,arg2,...)`. The `$` sigil introduces a function call; the name is a sequence of `[a-zA-Z0-9_]` characters; the argument list, enclosed in `(` … `)`, may be empty or contain comma-separated sub-expressions that are themselves full expressions.
- **Variables** — `%varname%`. A variable reference is delimited by a pair of `%` signs. The name may contain alphanumeric characters, underscores, and colons (the last permits multi-level identifiers such as `%musicbrainz:trackid%`).
- **Text** — everything else. Any characters that are not `$`, `%`, or `\` are passed through verbatim to the output.

Escape sequences allow special characters to appear in output: `\$`, `\%`, `\(`, `\)`, `\,`, `\\`, `\n`, `\t`, and `\uXXXX` (Unicode code point). The formal grammar embedded in both `picard-mode.el` and `grammar.js`, derived from the [Picard parser source](https://github.com/metabrainz/picard/blob/master/picard/script/parser.py), reads:

```
unicodechar ::= '\u' [a-fA-F0-9]{4}
text        ::= [^$%] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
argtext     ::= [^$%(),] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
identifier  ::= [a-zA-Z0-9_]
variable    ::= '%' (identifier | ':')+ '%'
function    ::= '$' (identifier)+ '(' (argument (',' argument)*)? ')'
expression  ::= (variable | function | text)*
argument    ::= (variable | function | argtext)*
```

### The `$noop()` Comment Mechanism

[`$noop`](https://picard-docs.musicbrainz.org/en/functions/func_noop.html) is a built-in function that does nothing and always returns the empty string. Its practical use is as the language's sole comment mechanism: `$noop( A comment. )` evaluates to `""`. Crucially, `$noop` may contain nested function calls and therefore nested parentheses: `$noop($set(foo,Testing...))` is a valid, well-formed noop that does not actually set `foo`.

This nesting property makes `$noop` the most interesting parsing challenge in the language. A regex such as `\$noop([^)]*)` cannot match it correctly, because the `)` that ends the noop may be preceded by an arbitrary number of inner `)` characters that belong to nested calls. Correct parsing requires depth tracking—a context-sensitive property that places the problem outside the reach of regular expressions and even context-free grammars expressed without explicit counters.

### Why Picard Is Interesting to Parse

Several properties make Picard Tagger Script unusual from a language-implementation perspective:

1. **Everything is a string.** There are no integers, booleans, or typed expressions at the language level. Every construct reduces to a string at runtime. This means there are no "keywords" in the traditional sense—`$if`, `$set`, and `$noop` are just function names.

2. **Tcl heritage.** The [official documentation](https://picard-docs.musicbrainz.org/v2.9/en/extending/scripting.html) notes that the syntax is derived from Tcl. Like Tcl, whitespace is significant (it appears verbatim in output strings), there is no reserved word set, and the boundary between code and data is entirely sigil-based.

3. **Sigil-driven tokenization.** The lexer is determined almost entirely by two characters (`$` and `%`). Every other character is text unless escaped. This means a naive implementation can be almost correct with only a handful of regex patterns—but exact correctness requires handling the `$noop` nesting, which breaks that simplicity.

4. **No line comments.** There is no `//`, `#`, or `;`-style single-line comment. `$noop(...)` is the only comment form, and it is inherently a block comment.

The [VS Code Tagger Script extension](https://github.com/phw/vscode-tagger-script) handles syntax highlighting for this language using TextMate grammars, which also cannot handle the nested `$noop` problem precisely—it highlights the first unmatched `)` as the comment end.

---

## Phase 1: Traditional Major Mode (`picard-mode.el`)

### Anatomy of an Emacs Major Mode

An Emacs major mode is a collection of buffer-local variable assignments that configure Emacs's editing infrastructure for a particular language. The canonical construction mechanism is the `define-derived-mode` macro:

```elisp
(define-derived-mode picard-mode prog-mode "Picard"
  "Major mode for editing MusicBrainz Picard Tagger Script files."
  ...)
```

`define-derived-mode` does several things automatically:

- It creates a new mode named `picard-mode` that inherits from `prog-mode` (the base class for programming language modes). Inheritance means that all hooks, keymaps, and variable settings established by `prog-mode` take effect first; `picard-mode` then supplements or overrides them.
- It generates a `picard-mode-map` (keymap) and `picard-mode-syntax-table` (syntax table), both of which the mode body may populate.
- It arranges for a `picard-mode-hook` to be run at the end of mode initialization, giving users a customization point.
- It sets `mode-name` to the display string `"Picard"` (shown in the mode line).

`prog-mode` provides foundational infrastructure shared by all programming modes: `comment-dwim` support, `electric-pair-mode` integration, `which-function-mode` support, `xref` hooks, and a consistent keymap structure. A mode derived from `prog-mode` therefore works immediately with many Emacs packages—`flycheck`, `company`, `eldoc`—without any special configuration.

The components that a mode must define are:

- **Syntax table** — how individual characters are classified.
- **Font-lock keywords** — what patterns receive which faces.
- **Indentation function** — `indent-line-function`.
- **Comment variables** — `comment-start`, `comment-end`, and friends.
- Optionally: a `syntax-propertize-function` for context-sensitive syntax properties.

### The Syntax Table: Character Classification

A [syntax table](https://www.gnu.org/software/emacs/manual/html_node/elisp/Syntax-Tables.html) is a char-table that maps each character to a *syntax descriptor*—a small data structure encoding the character's syntactic role. The descriptor governs how `forward-sexp`, `backward-sexp`, `mark-sexp`, `show-paren-mode`, and a large family of related commands perceive the buffer's structure.

Each character belongs to exactly one *syntax class*, identified by a one-character code in `modify-syntax-entry` notation:

| Code | Class | Meaning |
|------|-------|---------|
| ` ` (space) | whitespace | Ignored in sexp navigation |
| `w` | word constituent | Part of a word (`forward-word`, `M-d`) |
| `_` | symbol constituent | Part of a symbol but not a word |
| `(` | open-paren | Opens a balanced expression |
| `)` | close-paren | Closes a balanced expression |
| `"` | string delimiter | Starts/ends a string |
| `\` | escape | Causes next character to be taken literally |
| `.` | punctuation | Separates tokens; neither word nor symbol |
| `<` | comment start | Starts a single-line comment |
| `>` | comment end | Ends a single-line comment |
| `!` | comment fence | Fences a non-standard comment region |

`picard-mode` constructs its syntax table as follows:

```elisp
(defvar picard-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?$ "_" table)
    (modify-syntax-entry ?% "_" table)
    (modify-syntax-entry ?, "." table)
    (modify-syntax-entry ?: "_" table)
    table)
  "Syntax table for `picard-mode'.")
```

Each entry has a precise rationale:

**`(` and `)` as paired parens.** `(modify-syntax-entry ?\( "()" table)` assigns `(` the open-paren class with `)` as its matching character; `(modify-syntax-entry ?\) ")(" table)` does the reciprocal. With these entries in place, `forward-sexp` skips entire `$func(...)` argument lists, `show-paren-mode` highlights matching delimiters, and `C-M-f`/`C-M-b` navigate structural units. Without them, parentheses would be plain punctuation and none of the sexp-navigation commands would understand Picard's argument structure.

**`\` as escape.** `(modify-syntax-entry ?\\ "\\" table)` marks backslash as the escape character (syntax class `\`). This has a specific effect on paren-balance counting: Emacs skips the character immediately following an escape when scanning for matching parens. This ensures that `\(` inside a script is not counted as an unmatched open-paren, which would otherwise cause `show-paren-mode` to display a mismatch warning and `forward-sexp` to skip too far.

**`$` and `%` as symbol constituents.** By default, `$` and `%` are neither word nor symbol constituents in Emacs's standard syntax table—they are punctuation. Reclassifying them as symbol constituents (`_` class) means that `$funcname` and `%varname%` are each a single navigable token for `forward-symbol`, `M-b`/`M-f`, and font-lock patterns that use `\b`-style word boundaries. It also means that the font-lock regex `\$[a-zA-Z0-9_]+` can be expressed more naturally.

**`,` as punctuation.** Commas separate function arguments. The punctuation class (`.`) is the correct choice: it marks word and symbol boundaries without being whitespace. This ensures that `M-b` from inside an argument stops at the comma rather than skipping over it.

**`:` as symbol constituent.** Variable names such as `%musicbrainz:trackid%` contain colons. Making `:` a symbol constituent keeps the entire `musicbrainz:trackid` token navigable as a unit.

**No comment syntax.** Notably absent from the syntax table are any comment syntax entries. No `<`/`>` class characters, no `!` class. This is intentional: as explained below, `$noop(...)` comments cannot be described by fixed syntax-table entries because their boundaries depend on runtime depth tracking. They are instead established dynamically via `syntax-propertize-function`.

### Font-Lock: Regex-Based Syntax Highlighting

Emacs's font-lock system highlights buffers by running a set of patterns against the buffer text and applying faces to matched regions. The mode connects its pattern list to the system through `font-lock-defaults`:

```elisp
(setq-local font-lock-defaults
            '(picard-font-lock-keywords
              nil   ; KEYWORDS-ONLY: nil enables syntactic fontification
              nil   ; CASE-FOLD: nil = case-sensitive
              nil   ; SYNTAX-ALIST
              nil)) ; SYNTAX-BEGIN
```

The first element, `picard-font-lock-keywords`, is the list of pattern specifications. The second argument (`KEYWORDS-ONLY`) is `nil`, which instructs font-lock to perform *syntactic fontification* in addition to keyword fontification. Syntactic fontification is the phase that applies `font-lock-comment-face` and `font-lock-string-face` based on the buffer's syntax state—including the comment regions established by `syntax-propertize-function`. Setting this to `t` would suppress comment highlighting, breaking `$noop` display.

Each entry in `font-lock-keywords` takes one of two forms:

- `(REGEXP . FACE)` — highlights the entire match with FACE.
- `(REGEXP (GROUP FACE OVERRIDE LAXMATCH))` — highlights subgroup GROUP.

The third variant used here is `(REGEXP (0 FORM))` where FORM is evaluated at match time, allowing conditional highlighting.

The full keyword list for `picard-mode`:

```elisp
(defconst picard-font-lock-keywords
  `(
    ;; Escape sequences — must come first
    (,(rx (or (seq "\\" (any "nts$%()\\,"))
              (seq "\\u" (repeat 4 (any hex-digit)))))
     (0 'font-lock-constant-face))

    ;; Function names ($funcname) — exclude $noop
    (,(rx "$" (not (any space)) (zero-or-more (any alnum "_")))
     (0 (when (not (string-equal (match-string 0) "$noop"))
          'font-lock-function-name-face)))

    ;; Variable references (%varname%)
    (,(rx "%" (one-or-more (any alnum "_:")) "%")
     (0 'font-lock-variable-name-face))

    ;; Argument-separator commas
    ("," (0 picard--font-lock-delimiter-face))

    ;; $noop opening sigil
    (,(rx "$noop")
     (0 'font-lock-function-name-face prepend)))
  "Font-lock keyword specification for `picard-mode'.")
```

**Ordering strategy.** Escape sequences appear first in the list. Font-lock processes keywords in order and, by default, does not re-highlight a region already claimed by an earlier pattern. Placing escape sequences first ensures that `\$` and `\%` are highlighted as escape sequences (with `font-lock-constant-face`) rather than as the start of a function call or variable reference—which would happen if the `$funcname` pattern ran first.

**The `$noop` guard.** The function-name pattern uses the form `(0 (when ... 'face))`. At match time, `(match-string 0)` is the full matched text. If that text equals `"$noop"` exactly, the form returns `nil`, which font-lock interprets as "do not highlight." This prevents `$noop` from briefly appearing with `font-lock-function-name-face` during the re-fontification cycle before `syntax-propertize` has marked the region as a comment. The check uses `string-equal` rather than a regex prefix test, so hypothetical functions named `$noop2` or `$noop_helper` are correctly highlighted as functions.

**The `$noop` sigil entry.** A final entry matches `"$noop"` itself with `font-lock-function-name-face prepend`. The `prepend` flag means the face is blended with (prepended to) any existing face rather than replacing it. This makes `$noop` visually distinct as the function name even when it sits at the boundary of a comment region.

**Fallback face.** `font-lock-delimiter-face` was introduced in Emacs 29.1. For compatibility with earlier versions, the mode defines:

```elisp
(defvar picard--font-lock-delimiter-face
  (if (facep 'font-lock-delimiter-face)
      'font-lock-delimiter-face
    'font-lock-comment-delimiter-face)
  "Face used for argument-separator commas.")
```

This pattern—checking `facep` at load time and storing the resolved face in a variable—is the standard idiom for graceful backward compatibility without runtime `condition-case` overhead.

### `syntax-propertize-function`: Solving Nested Comments

This is the most important and novel part of `picard-mode`. It solves a problem that neither the syntax table nor font-lock keywords can address: correctly marking `$noop(...)` regions as comments when the body contains nested parentheses.

#### What `syntax-propertize-function` Is

[Emacs's syntax-propertize machinery](https://www.gnu.org/software/emacs/manual/html_node/elisp/Syntax-Tables.html) is a hook that runs before each font-lock pass. The variable `syntax-propertize-function`, when set buffer-locally, names a function that Emacs calls with two arguments—START and END—indicating the range of text whose syntax properties need refreshing (typically after an edit). The function's job is to apply `syntax-table` text properties to specific positions within that range, overriding the buffer-wide syntax table for those positions.

This mechanism exists precisely because some syntax cannot be expressed in a static character table. It is the correct tool whenever:

- Comment or string boundaries depend on context (nesting depth, preceding tokens, etc.).
- The same character has different syntactic roles in different positions (e.g., `%` as both variable opener and closer).
- Comment regions are computed by an algorithm rather than a fixed delimiter pair.

#### Why Regex Fails Here

The `$noop(...)` body may contain an arbitrary number of `(` characters:

```
$noop( This contains $if(condition, nested($call())) )
```

A regex that tries to find the matching `)` would need to know how many `(` characters precede each `)` —a counting problem that regular grammars cannot express. The practical failure mode: `\$noop([^)]*)` matches only `$noop($if(condition, nested($call(` and the `)` inside the nested call incorrectly terminates the match.

#### The Comment-Fence Mechanism

Emacs provides two special syntax codes for non-standard comment delimiters:

- **Code 11** — "comment start (generic fence style b)". A character with this syntax code begins a comment region.
- **Code 12** — "comment end (generic fence style b)". A character with this syntax code ends a comment region.

When Emacs's syntax scanner encounters a character carrying syntax code 11 via a text property, it treats everything from that position to the next syntax-code-12 character as a comment region. Font-lock's syntactic phase then applies `font-lock-comment-face` to the entire region automatically.

The cons cell `'(11 . ?!)` is the data structure used to specify this in a `syntax-table` text property. `11` is the integer syntax code; `?!` is an arbitrary "pairing character" required by the data structure format but not functionally meaningful for fence-style comments (it would matter for paired-delimiter styles like strings). Similarly, `'(12 . ?!)` marks a comment-end fence.

#### The Algorithm: Step-by-Step

```elisp
(defun picard--syntax-propertize (start end)
  "Apply syntax properties for $noop() comment blocks between START and END."
  (goto-char start)
  (while (re-search-forward "\\$noop(" end t)
    (let* ((noop-start (match-beginning 0))
           (_paren-open (1- (point)))
           (depth 1))
      ;; Mark the '$' as a comment-start fence.
      (put-text-property noop-start (1+ noop-start)
                         'syntax-table '(11 . ?!))
      ;; Walk forward, adjusting depth for each unescaped ( or ).
      (while (and (> depth 0) (< (point) end))
        (let ((ch (char-after)))
          (cond
           ;; Backslash escape: skip both the backslash and the next character.
           ((eq ch ?\\)
            (forward-char 2))
           ;; Opening paren: increase nesting depth.
           ((eq ch ?\()
            (setq depth (1+ depth))
            (forward-char 1))
           ;; Closing paren: decrease depth.
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
```

The algorithm proceeds as follows:

1. **Find `$noop(` with `re-search-forward`.** This regex is safe here because it only needs to locate the *start* of a noop block, not its end. The regex does not attempt to match the content or closing paren.

2. **Record `noop-start`.** `(match-beginning 0)` is the position of the `$` character. This is the position that will receive syntax code 11—making `$` the comment-start fence character.

3. **Mark the comment-start fence.** `(put-text-property noop-start (1+ noop-start) 'syntax-table '(11 . ?!))` applies a text property to the single character at `noop-start`. This overrides the buffer-wide syntax table for that one character: `$` now temporarily carries syntax code 11 (comment-start fence) rather than its table-wide value of symbol-constituent.

4. **Initialize depth = 1.** The opening `(` was already consumed by `re-search-forward` (since `$noop(` is the search pattern). Depth starts at 1 to represent that unmatched open paren.

5. **Walk forward character by character**, inspecting `(char-after)`:
   - If the character is `\`, advance two positions (skip the escape sequence). This prevents `\(` or `\)` inside the noop body from being counted as depth changes.
   - If the character is `(`, increment depth.
   - If the character is `)`, decrement depth. When depth reaches zero, this `)` is the matching close of the `$noop(` call. Mark it with syntax code 12 (comment-end fence) via `put-text-property`.

6. **Termination conditions.** The inner loop exits when either `depth` reaches 0 (well-formed noop) or `(point)` reaches `end` (noop block continues beyond the region being propertized—the function will be called again for the next region after further edits). The outer `while` loop then continues scanning for the next `$noop(`.

The result: after `picard--syntax-propertize` runs, the buffer has text properties at the `$` of each `$noop(` and the matching `)`, declaring them comment fences. Font-lock's syntactic pass then automatically renders everything in between with `font-lock-comment-face`. `parse-sexp-ignore-comments t` and `parse-sexp-lookup-properties t` (both set in the mode body) ensure that sexp navigation also respects these comment regions.

#### Integration with the Broader System

Two additional settings in the mode body are required for the text properties to take effect:

```elisp
(setq-local parse-sexp-ignore-comments t)
(setq-local parse-sexp-lookup-properties t)
```

`parse-sexp-lookup-properties t` tells Emacs's sexp-scanning engine to consult `syntax-table` text properties when present, rather than using only the buffer-wide syntax table. Without this, the comment fences would be written to the buffer but ignored by the scanner. `parse-sexp-ignore-comments t` causes sexp navigation to skip over comment regions.

### Indentation: Tab-Only Strategy

Picard scripts are sometimes embedded directly in file-path templates or tag transformation pipelines. In those contexts, leading spaces could appear literally in the output. The mode therefore enforces tab-only indentation: each nesting level adds one `TAB` character, never spaces.

The helper function `picard--count-net-parens` computes the net open-parenthesis count of a string:

```elisp
(defun picard--count-net-parens (text)
  "Return the net open-parenthesis count in TEXT."
  (let ((count 0)
        (i 0)
        (len (length text)))
    (while (< i len)
      (let ((ch (aref text i)))
        (cond
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
```

The escape-sequence skip (`setq i (+ i 2)` on backslash) is critical: `\(` and `\)` are not structural parens and must not alter the depth count.

`picard-indent-line` uses this helper to compute the current line's indentation:

```elisp
(defun picard-indent-line ()
  "Indent the current line in a Picard Tagger Script buffer."
  (interactive)
  (let ((indent-level 0))
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
    (setq indent-level (max 0 indent-level))
    (save-excursion
      (beginning-of-line)
      (delete-horizontal-space)
      (insert (make-string indent-level ?\t)))
    (when (< (current-column) indent-level)
      (beginning-of-line)
      (forward-char indent-level))))
```

The function walks all preceding non-empty lines from `point-min`, accumulating the net paren delta, then inserts that many tab characters at the beginning of the current line. The walk-from-top-level approach is simple and correct, though it scales linearly with buffer size; for scripts of typical length (tens to hundreds of lines) this is negligible.

`electric-indent-local-mode -1` disables the global `electric-indent-mode` locally. That mode inserts spaces after certain characters (notably after `)` and `,`), which would produce mixed-whitespace indentation inconsistent with the tab-only policy.

### Comment Variables

Five buffer-local variables teach Emacs's universal comment commands (`M-;` / `comment-dwim`, `comment-region`, `uncomment-region`) about `$noop`:

```elisp
(setq-local comment-start "$noop(")
(setq-local comment-end ")")
(setq-local comment-start-skip "\\$noop(\\s-*")
(setq-local block-comment-start "$noop(")
(setq-local block-comment-end ")")
(setq-local comment-padding "")
```

`comment-start` and `comment-end` are the strings `M-;` inserts when wrapping selected text in a comment. `comment-start-skip` is the regex Emacs uses to locate the beginning of an existing comment when stripping (`uncomment-region`) or navigating (`comment-search-forward`). It includes `\s-*` (optional whitespace) after the `(` to handle both `$noop(text)` and `$noop( text )` styles. `comment-padding ""` suppresses the automatic space Emacs normally inserts between the comment delimiter and the comment text, since the idiomatic Picard style is `$noop(text)` rather than `$noop( text )`.

---

## Phase 2: Tree-sitter Integration

### Background: Emacs 29 and `treesit.el`

Before Emacs 29, tree-sitter integration was provided by the third-party `tree-sitter.el` package (by Casper da Costa-Luis), which operated as a *minor mode overlay* on top of existing major modes. It would augment an existing mode with tree-sitter-based highlighting while leaving that mode's indentation, navigation, and other infrastructure in place. This created a hybrid architecture with inherent tensions: the minor mode and major mode could disagree about buffer syntax.

Emacs 29 introduced [`treesit.el`](https://tree-sitter.github.io/tree-sitter/) as a built-in library with a fundamentally different architecture: new dedicated major modes (named `*-ts-mode` by convention) that delegate their entire parsing infrastructure to the tree-sitter runtime. There is no regex fallback within the mode—the tree-sitter parser is the authoritative source of syntax information. `python-ts-mode`, `c-ts-mode`, `rust-ts-mode`, and so on are all clean rewrites of their predecessors using this API.

[Tree-sitter](https://tree-sitter.github.io/tree-sitter/) itself is an incremental parsing library written in C. It builds a concrete syntax tree for a buffer and efficiently updates that tree after each edit, re-parsing only the changed region rather than the entire buffer. This property—incremental parsing—means the parse overhead is proportional to the size of the change, not the size of the file, which keeps highlighting responsive even in large buffers.

The advantages of the tree-sitter architecture over regex-based highlighting are:

- **No false matches.** The parser understands nesting, so a function name inside a comment does not get `font-lock-function-name-face`.
- **Structural queries.** Highlighting is expressed as tree structure queries rather than as patterns on flat text, which naturally handles nested and recursive constructs.
- **Reusability.** The same grammar can be used by Emacs, Neovim, Helix, GitHub's code search, and any other tool that embeds the tree-sitter runtime.

### The Grammar: `grammar.js`

A tree-sitter grammar is specified in JavaScript using the grammar DSL:

```javascript
module.exports = grammar({
  name: 'taggerscript',
  externals: $ => [ $._noop_content ],
  extras: () => [],
  conflicts: () => [],
  rules: { ... }
});
```

`module.exports = grammar({...})` defines the grammar object that the tree-sitter CLI's `generate` command compiles into C source files (`parser.c`) and, ultimately, a shared library.

#### The `extras` Array

`extras: () => []` is critical for Picard. In most grammars, `extras` lists the tokens that can appear between any two other tokens without being syntactically significant—typically whitespace and comments. Tree-sitter uses this list to insert automatic "skip these" rules throughout the grammar. For Picard, whitespace is **not** extra: a space in a Picard script is a space in the output string. Setting `extras` to the empty array means every character must be explicitly handled by a rule. Whitespace is captured by the `text` and `argument_text` rules as literal content.

#### The Rule Hierarchy

The grammar defines a hierarchy of rules:

```javascript
source_file: $ => repeat($._expression),

_expression: $ => choice(
  $.variable,
  $.noop,
  $.function_call,
  $.escape_sequence,
  $.text,
),
```

`source_file` is the top-level rule: a document is zero or more expressions. `_expression` is a *hidden rule* (its name begins with `_`). Hidden rules do not produce named nodes in the syntax tree; their children are inlined into the parent. This means the tree for `$lower(%artist%)` does not have an `_expression` node—it has `function_call` and `variable` nodes directly under `source_file`.

The full set of named rules:

```javascript
variable: $ => seq('%', field('name', $.variable_name), '%'),
variable_name: () => /[a-zA-Z0-9_:]+/,

noop: $ => prec(1, seq('$noop', field('body', $._noop_content))),

function_call: $ => seq(
  '$',
  field('name', $.function_name),
  '(',
  optional($._argument_list),
  ')',
),
function_name: () => /[a-zA-Z0-9_]+/,

_argument_list: $ => seq($.argument, repeat(seq(',', $.argument))),

argument: $ => repeat1(choice(
  $.variable,
  $.noop,
  $.function_call,
  $.escape_sequence,
  $.argument_text,
)),

escape_sequence: () => token(choice(
  /\\[$%()\\,\\nt]/,
  /\\u[0-9a-fA-F]{4}/,
)),

text: () => token(/[^$%\\]+/),

argument_text: () => token(/[^$%()\\,]+/),
```

**`field()` for named child access.** The `field('name', ...)` call assigns a named field to a child node. In the syntax tree, the `function_call` node's `function_name` child is accessible as `(function_call name: (function_name))` in query patterns, and via `treesit-node-child-by-field-name node "name"` in Elisp. Fields make queries more precise: `(function_call name: (function_name) @font-lock-function-call-face)` highlights only function names that are in the `name` field position, not any `function_name` node that might appear elsewhere.

**`token()` for atomic matching.** `token(...)` wraps a regex or choice to indicate that the match should be a single atomic terminal token, not further decomposed. Without `token()`, the `choice(...)` inside `escape_sequence` would potentially create intermediate nodes. With `token()`, the entire match is a single leaf.

**The `prec(1, ...)` trick.** Both `noop` and `function_call` match a prefix starting with `$`. The parser would be ambiguous about how to parse `$noop(...)`: is it a `noop` node or a `function_call` named "noop"? `prec(1, seq('$noop', ...))` assigns the `noop` rule higher precedence (1) than `function_call` (default 0), resolving the conflict in favor of the comment interpretation.

**Hidden `_argument_list`.** Because `_argument_list` is hidden, it does not produce an extra wrapping node in the tree. The argument nodes appear directly as children of `function_call`, which simplifies both query patterns and Elisp navigation code.

**`text` vs `argument_text`.** Two text rules exist because the excluded character set differs by context. At the top level, `text` excludes only `$`, `%`, and `\`. Inside a function argument, `argument_text` additionally excludes `(`, `)`, and `,` (which would otherwise be misread as argument-list delimiters). This context-sensitivity cannot be expressed with a single regex; it requires two distinct rules at different positions in the grammar hierarchy.

### The External Scanner: `scanner.c`

The grammar's `externals` declaration identifies `_noop_content` as an *external token*—one whose recognition is delegated to a hand-written C scanner rather than to the generated parser. External scanners are necessary when the PEG grammar DSL is not expressive enough to handle a construct. Nested balanced delimiters are the canonical example: they require a counter, which is not expressible in a context-free grammar without extension.

#### The Scanner API

The tree-sitter runtime requires five exported C functions, all following the naming convention `tree_sitter_LANGUAGE_external_scanner_FUNCTION`:

```c
void  *tree_sitter_taggerscript_external_scanner_create(void);
void   tree_sitter_taggerscript_external_scanner_destroy(void *payload);
unsigned tree_sitter_taggerscript_external_scanner_serialize(void *payload, char *buffer);
void   tree_sitter_taggerscript_external_scanner_deserialize(void *payload, const char *buffer, unsigned length);
bool   tree_sitter_taggerscript_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols);
```

Their roles:

- **`create`** — allocates and returns a scanner state object. For stateless scanners, returns `NULL`.
- **`destroy`** — frees the state object. No-op here since `create` returns `NULL`.
- **`serialize`** — writes the scanner's state to a byte buffer for incremental parse caching. Returns 0 bytes for this stateless scanner.
- **`deserialize`** — restores state from a previously serialized buffer. No-op here.
- **`scan`** — the main entry point, called whenever the parser needs one of the external tokens.

#### The Scan Function: Depth Tracking

```c
bool tree_sitter_taggerscript_external_scanner_scan(
    void *payload,
    TSLexer *lexer,
    const bool *valid_symbols
) {
    (void)payload;

    if (!valid_symbols[NOOP_CONTENT]) {
        return false;
    }

    int depth = 1;

    while (depth > 0) {
        if (lexer->eof(lexer)) {
            return false;
        }

        int32_t c = lexer->lookahead;
        lexer->advance(lexer, false);

        if (c == '(') {
            depth++;
        } else if (c == ')') {
            depth--;
        }
    }

    lexer->result_symbol = NOOP_CONTENT;
    return true;
}
```

`valid_symbols[NOOP_CONTENT]` is the first check. The runtime calls `scan` with a boolean array indicating which external tokens are currently valid given the parser's state. If `NOOP_CONTENT` is not valid, returning `false` immediately tells the runtime this scanner cannot produce a token, and the parser proceeds with its built-in rules.

The depth counter starts at 1 because the grammar rule for `noop` has already consumed `$noop` and `(` before delegating to the external scanner:

```javascript
noop: $ => prec(1, seq('$noop', field('body', $._noop_content))),
```

The literal `'$noop'` and the implicit `'('` in the grammar are matched by the main parser; the scanner receives control immediately after that `(`, with the lookahead positioned at the first character of the body. The scanner therefore reads the body starting at depth 1.

`lexer->advance(lexer, false)` advances one character. The second argument is `skip` (false here)—setting it to true would mark the consumed character as not part of the token (used for skipping whitespace in languages where whitespace is extra). Since all characters in the noop body are part of the token, `skip` is always false.

`lexer->eof(lexer)` detects end-of-file. An unterminated `$noop(` is a parse error; the scanner returns `false` so the parser can emit an error node rather than silently accepting malformed input. This is the correct behavior: tree-sitter is designed to produce useful trees even with errors, and returning false here participates in that error-recovery mechanism.

Setting `lexer->result_symbol = NOOP_CONTENT` before returning `true` communicates which external token is being emitted. The runtime uses this value to construct the corresponding leaf node in the syntax tree.

**Statefulness.** The scanner is stateless because all depth tracking is local to the `scan` invocation. `serialize` returns 0 bytes. This is sufficient here because `$noop` bodies are always consumed in a single call. In more complex cases—where a scanner must carry state across `scan` calls (e.g., tracking heredoc identifiers in shell grammars)—`serialize` and `deserialize` would write and read that state, enabling correct incremental re-parsing after edits.

---

### The Emacs Frontend: `picard-ts-mode.el`

`picard-ts-mode.el` is the Emacs 29+ mode that connects the tree-sitter grammar to Emacs's editor infrastructure. It requires `(require 'treesit)` (the built-in library) and optionally `(require 'picard-mode nil 'noerror)` (the traditional mode, for shared customization variables).

#### `treesit-font-lock-rules`

Font-lock in tree-sitter modes is expressed as S-expression queries in the tree-sitter pattern language, compiled by `treesit-font-lock-rules`:

```elisp
(defvar picard-ts-mode--font-lock-settings
  (treesit-font-lock-rules

   :language 'taggerscript
   :feature 'comment
   '((noop) @font-lock-comment-face)

   :language 'taggerscript
   :feature 'function
   '((function_call name: (function_name) @font-lock-function-call-face))

   :language 'taggerscript
   :feature 'variable
   :override t
   '((variable (variable_name) @font-lock-variable-use-face)
     (variable "%" @font-lock-bracket-face))

   :language 'taggerscript
   :feature 'escape-sequence
   :override t
   '((escape_sequence) @font-lock-escape-face)

   :language 'taggerscript
   :feature 'delimiter
   '((function_call "(" @font-lock-bracket-face)
     (function_call ")" @font-lock-bracket-face)
     (function_call "," @font-lock-delimiter-face))

   :language 'taggerscript
   :feature 'string
   :override 'keep
   '((text) @font-lock-string-face)))
```

`treesit-font-lock-rules` accepts a flat property list of keyword/value pairs interspersed with query patterns. The three mandatory keywords per rule group are:

- **`:language SYMBOL`** — which grammar the queries belong to. Must match the symbol passed to `treesit-parser-create` (`taggerscript` here).
- **`:feature SYMBOL`** — a logical name for this group of rules. Features can be independently toggled and are assigned to decoration levels via `treesit-font-lock-feature-list`.
- A query pattern (an S-expression or list of S-expressions following the keywords).

The optional **`:override`** keyword controls face merging:

| Value | Behavior |
|-------|----------|
| `nil` (default) | Do not override; skip if already fontified |
| `t` | Always override existing face |
| `'prepend` | Prepend to existing face list |
| `'append` | Append to existing face list |
| `'keep` | Apply only if face not yet set |

**Query pattern syntax.** A query pattern like `(function_call name: (function_name) @font-lock-function-call-face)` reads: "match a `function_call` node that has a child named `name` which is a `function_name` node; capture that `function_name` node under `@font-lock-function-call-face`." The `@` prefix introduces a capture name; capture names that start with `@font-lock-` are mapped to standard Emacs faces by stripping the prefix and resolving the remainder as a face symbol.

**Anonymous node matching.** The delimiter rule `(function_call "(" @font-lock-bracket-face)` matches anonymous nodes—nodes that are defined in the grammar as literal strings rather than named rules. Anonymous nodes are matched in queries by their literal text in double quotes. The `"$noop"` literal in the `noop` rule is also an anonymous node, accessible in queries as `"$noop"`.

**The `variable` rule and `%` delimiters.** The `variable` feature rule applies two captures to a single `variable` node:

```
(variable (variable_name) @font-lock-variable-use-face)
(variable "%" @font-lock-bracket-face)
```

The first applies `font-lock-variable-use-face` to the `variable_name` child. The second applies `font-lock-bracket-face` to both anonymous `%` nodes (the grammar's `variable` rule has `seq('%', field('name', $.variable_name), '%')`, producing two `%` anonymous nodes). `:override t` ensures these captures take effect even if the `text` rule has already applied `font-lock-string-face` to the whole region.

#### `treesit-font-lock-feature-list`

Progressive decoration assigns features to levels:

```elisp
(defvar picard-ts-mode--font-lock-feature-list
  '((comment)
    (function variable)
    (escape-sequence delimiter)
    (string))
  "Feature list for `picard-ts-mode' progressive font-lock decoration.")
```

The value is a list of lists. Each inner list names features active at that decoration level and all levels above it:

| Level | Features active | Default? |
|-------|----------------|----------|
| 1 | `comment` | Yes (included in level 3 default) |
| 2 | `comment`, `function`, `variable` | Yes |
| 3 (default) | `comment`, `function`, `variable`, `escape-sequence`, `delimiter` | Yes |
| 4 | All features | No |

`treesit-font-lock-level` defaults to 3, so `string`-level text decoration is off by default. Users who want plain text highlighted as `font-lock-string-face` can set `(setq treesit-font-lock-level 4)`. The design principle—placing the most semantically important highlights (comments, definitions) at lower levels and pure aesthetic decoration (text coloring) at higher levels—follows the convention established by all built-in ts-modes.

#### `treesit-simple-indent-rules`

Indentation rules are specified as a list of `(LANGUAGE . RULE-LIST)` pairs:

```elisp
(defvar picard-ts-mode--indent-rules
  `((taggerscript
     ((node-is ")") parent-bol 0)
     ((parent-is "argument") parent-bol ,tab-width)
     ((parent-is "function_call") parent-bol ,tab-width)
     ((parent-is "noop") parent-bol 0)
     ((parent-is "source_file") parent-bol 0)
     (no-node parent-bol 0))))
```

Each rule is a **MATCHER / ANCHOR / OFFSET** triple:

- **MATCHER** — a predicate receiving `(NODE PARENT BOL)` (current node, its parent node, beginning of current line). Returns non-nil if the rule applies. `treesit-simple-indent-presets` provides ready-made matchers:
  - `(node-is ")")` — matches when the node at the beginning of the line is a `)`.
  - `(parent-is "argument")` — matches when the current node's parent is an `argument` node.
  - `no-node` — matches when there is no node at BOL (blank line).
- **ANCHOR** — a function returning the reference column. `parent-bol` returns the beginning-of-line position of the line containing the parent node. `prev-sibling` would return the start of the previous sibling node.
- **OFFSET** — an integer added to the anchor column. Positive values indent right; zero means column-aligned with the anchor.

The rule `((node-is ")") parent-bol 0)` aligns closing parens with the start of their parent function call's line, producing:

```
$if(%condition%,
  value_true,
  value_false
)
```

The rules `((parent-is "argument") parent-bol tab-width)` and `((parent-is "function_call") parent-bol tab-width)` indent argument content one tab stop relative to the function call. The `tab-width` variable is back-quoted (`,tab-width`) so the current value is captured at the time the variable is defined.

#### Defun Navigation and Imenu

```elisp
(defvar picard-ts-mode--defun-type-regexp
  (rx (or "function_call" "noop"))
  "Regexp matching tree-sitter node types treated as defuns.")
```

`treesit-defun-type-regexp` is matched against node type names. When a node's type matches, it is treated as a structural unit for `C-M-a` (`beginning-of-defun`) and `C-M-e` (`end-of-defun`). Both `function_call` and `noop` are included, so these commands navigate between any top-level `$func(...)` or `$noop(...)` invocation.

Imenu integration indexes function calls for the code outline:

```elisp
(defun picard-ts-mode--imenu-name (node)
  "Return the display name for NODE in the Imenu index."
  (when-let* ((name-node (treesit-node-child-by-field-name node "name")))
    (treesit-node-text name-node t)))

(defvar picard-ts-mode--imenu-settings
  `(("Functions" "\\`function_call\\'" nil picard-ts-mode--imenu-name)))
```

`treesit-simple-imenu-settings` entries have the form `(CATEGORY NODE-TYPE-REGEXP PREDICATE NAME-FUNCTION)`. The regex `\`function_call\'` matches only `function_call` nodes exactly. `picard-ts-mode--imenu-name` retrieves the `function_name` child via the `"name"` field and converts it to text with `treesit-node-text`. The resulting Imenu index lists entries like `if`, `set`, `lower`, `pad` corresponding to each top-level `$if(...)`, `$set(...)`, etc.

#### The Transparent Upgrade: `major-mode-remap-alist`

```elisp
;;;###autoload
(when (and (fboundp 'treesit-ready-p)
           (treesit-ready-p 'taggerscript t))
  (add-to-list 'major-mode-remap-alist '(picard-mode . picard-ts-mode)))
```

`major-mode-remap-alist`, introduced in Emacs 29, is an alist mapping major mode symbols to replacement major mode symbols. When Emacs is about to activate `picard-mode` for a buffer (e.g., because the file has the `.picard` extension and `auto-mode-alist` maps it to `picard-mode`), it first consults `major-mode-remap-alist`. If an entry matches, it activates the mapped mode instead.

The guard `(fboundp 'treesit-ready-p)` checks that the treesit library is present (Emacs 29+). `(treesit-ready-p 'taggerscript t)` checks that the compiled grammar is available; the second argument `t` (QUIET) suppresses any warning if the grammar is missing. The remap is only registered when both conditions are true—users without the grammar continue to get `picard-mode` unmodified.

This mechanism is superior to modifying `auto-mode-alist` because:

1. Users who explicitly set `picard-mode` in their configuration are not overridden—`major-mode-remap-alist` only intercepts the automatic activation path.
2. Packages that programmatically call `(picard-mode)` get the upgraded mode automatically.
3. Removing the grammar (by deleting the `.so` file) reverts behavior to `picard-mode` without any configuration changes.

The mode body itself also handles the grammar-absent case gracefully:

```elisp
(when (treesit-ready-p 'taggerscript)
  (treesit-parser-create 'taggerscript)
  (picard-ts-mode--setup))
```

If `treesit-ready-p` returns nil (grammar not found), the mode still activates as a `prog-mode` derivative with the syntax table and comment variables, but without tree-sitter highlighting or indentation. A warning is emitted to the echo area.

---

## Architecture Comparison

| Concern | `picard-mode.el` (Traditional) | `picard-ts-mode.el` (Tree-sitter) |
|---------|-------------------------------|-----------------------------------|
| **Syntax analysis** | Emacs syntax table + `syntax-propertize-function` | Compiled C parser (`tree_sitter_taggerscript`) |
| **Highlighting** | `font-lock-keywords` with regex patterns | `treesit-font-lock-rules` with S-expression queries |
| **Comment marking** | Manual depth-tracking loop writing `syntax-table` text properties | Parser natively understands `noop` as a distinct node type |
| **`$noop` nesting** | Counted by `picard--syntax-propertize` at fontification time | Counted by `scanner.c` at parse time, result cached in tree |
| **Indentation** | `picard-indent-line` walks all preceding lines to sum net parens | `treesit-simple-indent-rules` consults the live syntax tree |
| **Navigation** | `forward-sexp` driven by syntax table | `beginning-of-defun`/`end-of-defun` driven by `treesit-defun-type-regexp` |
| **Imenu** | Not implemented | `treesit-simple-imenu-settings` with field-based name extraction |
| **Emacs version** | 27.1+ | 29.1+ (requires `treesit.el`) |
| **Grammar dependency** | None | `libtree-sitter-taggerscript.so` (compiled separately) |
| **Re-parse cost** | O(region size) regex scan on each edit | O(edit size) incremental update |
| **Correctness** | Regex approximation (correct for well-formed input) | Exact parse (correct including error recovery) |
| **Extensibility** | Adding features requires new regex patterns | Adding features requires new grammar rules or query patterns |
| **External tooling** | Emacs-only | Grammar reusable by Neovim, Helix, GitHub Linguist, etc. |

---

## Building and Installing

### Grammar Compilation

The tree-sitter grammar must be compiled to a native shared library before `picard-ts-mode` can function. The `tree-sitter` CLI (distributed via `npm`) handles this:

```bash
cd tree-sitter-taggerscript
npm install
npx tree-sitter generate
npx tree-sitter test
```

`npm install` downloads the `tree-sitter-cli` package and its dependencies.

`npx tree-sitter generate` reads `grammar.js`, resolves the `externals` array, compiles `grammar.js` to `src/parser.c` (the main parser tables), and produces a `Makefile` and `binding.gyp` for native compilation. The external scanner `src/scanner.c` is compiled alongside `src/parser.c`.

`npx tree-sitter test` runs the corpus of tests in the `test/` directory (if present), verifying that the generated parser produces the expected syntax trees.

To compile the shared library and install it in Emacs's grammar directory:

```bash
# Option A: use the Emacs built-in installer
emacs --batch --eval "(require 'treesit)" \
      --eval "(add-to-list 'treesit-language-source-alist
               '(taggerscript \"https://github.com/user/tree-sitter-taggerscript\"))" \
      --eval "(treesit-install-language-grammar 'taggerscript)"

# Option B: compile manually and copy
npx tree-sitter build
cp libtree-sitter-taggerscript.so ~/.emacs.d/tree-sitter/
```

Emacs looks for grammar libraries in `treesit-extra-load-path` first, then the default user grammar directory (`~/.emacs.d/tree-sitter/` on most systems).

### Emacs Setup

**Minimal setup** (manual `require`):

```elisp
(require 'picard-mode)       ; traditional mode (Emacs 27.1+)
(require 'picard-ts-mode)    ; tree-sitter mode (Emacs 29.1+)
```

`picard-ts-mode` loads `picard-mode` with `noerror`, so loading just `picard-ts-mode` is sufficient. The `auto-mode-alist` entries and `major-mode-remap-alist` registration are handled automatically.

**With `use-package`**:

```elisp
(use-package picard-mode
  :mode ("\\.picard\\'" "\\.pts\\'"))

(use-package picard-ts-mode
  :after picard-mode
  :if (treesit-available-p)
  :config
  ;; Optional: auto-install grammar if not present
  (unless (treesit-ready-p 'taggerscript t)
    (picard-ts-mode-install-grammar)))
```

**Grammar auto-installation.** `picard-ts-mode-install-grammar` is a convenience command defined in `picard-ts-mode.el` that calls `treesit-install-language-grammar` after ensuring the source entry is in `treesit-language-source-alist`:

```elisp
(defun picard-ts-mode-install-grammar ()
  "Install the taggerscript Tree-sitter grammar for `picard-ts-mode'."
  (interactive)
  (unless (assq 'taggerscript treesit-language-source-alist)
    (add-to-list 'treesit-language-source-alist
                 picard-ts-mode--grammar-source))
  (treesit-install-language-grammar 'taggerscript)
  (message "taggerscript grammar installed. \
Revert Picard Script buffers to activate tree-sitter mode."))
```

After installation, running `M-x revert-buffer` in any open `.picard` file activates the tree-sitter mode.

**Font-lock level tuning.** The default decoration level (3) activates `comment`, `function`, `variable`, `escape-sequence`, and `delimiter` features. To enable level-4 text decoration:

```elisp
(add-hook 'picard-ts-mode-hook
          (lambda () (setq-local treesit-font-lock-level 4)))
```

---

## Conclusion

The development of these two modes illustrates a progression in the state of the art for Emacs language support:

**The traditional approach** (`picard-mode.el`) demonstrates that Emacs's syntax table and `syntax-propertize-function` together form a surprisingly powerful system. The syntax table handles the common case (balanced parens, escape characters, symbol navigation) with zero per-edit overhead. `syntax-propertize-function` handles the exception (nested `$noop` comments) with a tight, readable loop that writes only the two text properties strictly necessary for correctness. Font-lock then composes with both: syntactic fontification respects the comment fences written by `syntax-propertize`, and keyword fontification handles the remaining highlighting via ordered regex patterns. The ordering discipline—escape sequences first, then function names with a guard against `$noop`, then variables—ensures correctness without any explicit conflict resolution mechanism.

**The tree-sitter approach** (`picard-ts-mode.el` + the grammar) separates concerns more cleanly. The `$noop` nesting problem, which required a carefully designed runtime algorithm in the traditional mode, becomes a straightforward external scanner in C: 40 lines of depth-counting code in `scanner.c`, invoked at parse time rather than fontification time. The result is cached in the syntax tree and updated incrementally on each edit—not recomputed for every fontification region. Highlighting is expressed as structural queries that cannot be confused by nesting or context, indentation is a declarative rule table rather than an imperative walker, and the entire grammar is reusable outside Emacs.

The `major-mode-remap-alist` upgrade mechanism completes the picture: users can install the traditional mode and use it indefinitely, then install the grammar later and immediately get the tree-sitter mode without changing any configuration. The two modes coexist as complementary solutions—one requiring only Emacs 27.1 and no native dependencies, the other requiring Emacs 29.1 and a compiled grammar but delivering a substantially more robust editing experience.

The key architectural lessons:

1. **`syntax-propertize-function` is the right tool for context-sensitive syntax** that cannot be expressed in a static syntax table—particularly nested-delimiter constructs like `$noop(...)`.
2. **Font-lock keyword ordering matters**: escape sequences must precede sigil-based patterns, or `\$` and `\%` will be misread as function or variable starts.
3. **Tree-sitter's `extras: []` is necessary for languages where whitespace is content**, not structure.
4. **External scanners are the tree-sitter escape hatch** for constructs (nested balanced delimiters, heredocs, indentation-sensitive whitespace) that require state a PEG grammar cannot track.
5. **`major-mode-remap-alist` is the correct upgrade mechanism**: it intercepts automatic mode activation without overriding explicit user configuration or breaking programmatic mode invocation.
