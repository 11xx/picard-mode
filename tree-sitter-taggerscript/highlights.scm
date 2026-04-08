; highlights.scm — Tree-sitter highlight queries for Picard Tagger Script
;
; These queries follow the standard nvim-treesitter / Helix capture naming
; convention so the grammar integrates with editors beyond Emacs.  The
; picard-ts-mode.el file defines its own Emacs-specific font-lock rules via
; `treesit-font-lock-rules', but this file enables out-of-the-box highlighting
; in Neovim, Helix, and any editor that reads queries/highlights.scm.

; Comments — $noop(...) blocks
(noop) @comment

; Function calls
(function_call
  "$" @function.builtin
  name: (function_name) @function.builtin)

; Variables — %name%
(variable
  "%" @variable.builtin
  name: (variable_name) @variable.builtin
  "%" @variable.builtin)

; Escape sequences
(escape_sequence) @string.escape

; Delimiters inside function calls
(function_call
  "(" @punctuation.bracket)
(function_call
  ")" @punctuation.bracket)
(function_call
  "," @punctuation.delimiter)

; Literal text
(text) @string
(argument_text) @string
