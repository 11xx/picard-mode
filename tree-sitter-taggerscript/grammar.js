/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

/**
 * Tree-sitter grammar for MusicBrainz Picard Tagger Script
 *
 * Design rationale
 * ----------------
 * Picard Tagger Script is a minimal expression language embedded in MusicBrainz
 * Picard's tagging pipeline.  Its grammar has two special sigil characters:
 *
 *   $  – introduces a function call whose arguments are enclosed in ( ... )
 *   %  – wraps a variable reference, e.g. %artist%
 *
 * All other character sequences are treated as literal text that passes through
 * unchanged.  Whitespace and newlines are therefore significant (they appear
 * verbatim in tag values) and are NOT listed in `extras`.
 *
 * The one non-trivial parsing challenge is `$noop(...)`, which serves as the
 * comment mechanism.  The body of a noop call is entirely opaque – it must
 * swallow nested parentheses without interpreting the content as further
 * functions or variables.  An external C scanner (`src/scanner.c`) is used to
 * handle this: it reads characters verbatim while tracking paren depth, emitting
 * the whole span as a single `_noop_content` token once the matching closing
 * paren is found.
 *
 * The external token `_noop_content` is consumed by the `noop` rule, which is
 * given higher precedence than the generic `function_call` rule so that the
 * parser always prefers the comment interpretation when it sees `$noop(`.
 *
 * Formal grammar (from the official Picard source)
 * -------------------------------------------------
 *   unicodechar ::= '\u' [a-fA-F0-9]{4}
 *   text        ::= [^$%] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
 *   argtext     ::= [^$%(),] | '\$' | '\%' | '\(' | '\)' | '\,' | unicodechar
 *   identifier  ::= [a-zA-Z0-9_]
 *   variable    ::= '%' (identifier | ':')+ '%'
 *   function    ::= '$' (identifier)+ '(' (argument (',' argument)*)? ')'
 *   expression  ::= (variable | function | text)*
 *   argument    ::= (variable | function | argtext)*
 */

module.exports = grammar({
  name: 'taggerscript',

  // ---------------------------------------------------------------------------
  // External tokens
  // ---------------------------------------------------------------------------
  // _noop_content is produced by the external scanner in src/scanner.c.
  // It matches everything between the opening '(' and the balancing closing ')'
  // of a $noop call, consuming the closing ')' itself so the noop rule does not
  // need to match it separately.
  externals: $ => [
    $._noop_content,
  ],

  // ---------------------------------------------------------------------------
  // Extras
  // ---------------------------------------------------------------------------
  // Whitespace is intentionally excluded from extras because spaces and newlines
  // are meaningful output characters in Tagger Script.  They are captured by the
  // `text` rule instead.
  extras: () => [],

  // ---------------------------------------------------------------------------
  // Conflicts
  // ---------------------------------------------------------------------------
  // No ambiguous rules require explicit conflict resolution beyond the
  // precedence annotations already applied to `noop` vs `function_call`.
  conflicts: () => [],

  // ---------------------------------------------------------------------------
  // Rules
  // ---------------------------------------------------------------------------
  rules: {

    // -------------------------------------------------------------------------
    // source_file – top-level document
    // -------------------------------------------------------------------------
    // A Tagger Script document is a flat sequence of expressions.  There is no
    // enclosing block structure; the entire file is one implicit expression.
    source_file: $ => repeat($._expression),

    // -------------------------------------------------------------------------
    // _expression – the three kinds of top-level expression atom
    // -------------------------------------------------------------------------
    // An expression is any mixture of variables, function calls (including noop),
    // escape sequences, and literal text.  This hidden rule is the union used
    // both at the top level (`source_file`) and recursively inside arguments.
    _expression: $ => choice(
      $.variable,
      $.noop,
      $.function_call,
      $.escape_sequence,
      $.text,
    ),

    // -------------------------------------------------------------------------
    // variable – %name%
    // -------------------------------------------------------------------------
    // Variable references are delimited by percent signs.  The name may contain
    // alphanumeric characters, underscores, and colons (the colon is used in
    // multi-level names such as %musicbrainz:trackid%).
    variable: $ => seq(
      '%',
      field('name', $.variable_name),
      '%',
    ),

    // -------------------------------------------------------------------------
    // variable_name – the identifier between the percent delimiters
    // -------------------------------------------------------------------------
    // One or more characters drawn from [a-zA-Z0-9_:].
    variable_name: () => /[a-zA-Z0-9_:]+/,

    // -------------------------------------------------------------------------
    // noop – $noop(...) comment construct
    // -------------------------------------------------------------------------
    // $noop is the only way to embed comments in Tagger Script.  Its body is
    // treated as opaque text: nested parentheses are allowed and the content is
    // never interpreted as functions or variables.
    //
    // Higher precedence (1) ensures the parser picks this rule over the generic
    // `function_call` rule when both could match a `$noop(` prefix.
    noop: $ => prec(1, seq(
      '$noop(',
      field('body', $._noop_content),
    )),

    // -------------------------------------------------------------------------
    // function_call – $name(arg, arg, ...)
    // -------------------------------------------------------------------------
    // The primary structural construct in Tagger Script.  A function call begins
    // with '$', followed by a name composed of [a-zA-Z0-9_]+, then a
    // parenthesised, comma-separated list of zero or more arguments.
    function_call: $ => seq(
      '$',
      field('name', $.function_name),
      '(',
      optional($._argument_list),
      ')',
    ),

    // -------------------------------------------------------------------------
    // function_name – the identifier after the '$' sigil
    // -------------------------------------------------------------------------
    function_name: () => /[a-zA-Z0-9_]+/,

    // -------------------------------------------------------------------------
    // _argument_list – comma-separated sequence of arguments
    // -------------------------------------------------------------------------
    // Arguments are separated by commas.  Crucially, any argument position may
    // be EMPTY – Picard treats empty arguments as empty strings.  Examples:
    //   $if(a,b,)    – three arguments, last is empty
    //   $if(a,,c)    – three arguments, middle is empty
    //   $if(,,,)     – four empty arguments
    //
    // Tree-sitter forbids rules that match the empty string, so the list is
    // structured as: either a single non-empty argument, or one or more
    // comma-separated slots where each slot's content is optional.  A bare
    // comma always signals the presence of an argument boundary even when both
    // adjacent slots are empty.
    _argument_list: $ => choice(
      // Case 1: single argument with no commas  –  $func(arg)
      $.argument,
      // Case 2: at least one comma exists  –  covers all multi-arg and
      // empty-arg scenarios including $func(,), $func(a,), $func(,a),
      // $func(a,b,c), $func(,,) etc.
      seq(
        optional($.argument),
        repeat1(seq(',', optional($.argument))),
      ),
    ),

    // -------------------------------------------------------------------------
    // argument – content of a single function argument
    // -------------------------------------------------------------------------
    // An argument may contain variables, nested function calls (including noop),
    // escape sequences, and argument-text.  Argument text is a restricted form
    // of text that excludes the special characters '(', ')', and ',' so the
    // parser can unambiguously locate argument boundaries.
    //
    // When an argument position is empty (e.g. between consecutive commas or
    // before ')'), no `argument` node is produced — the `optional()` wrapper
    // in `_argument_list` simply yields nothing.
    argument: $ => repeat1(
      choice(
        $.variable,
        $.noop,
        $.function_call,
        $.escape_sequence,
        $.argument_text,
      ),
    ),

    // -------------------------------------------------------------------------
    // escape_sequence – backslash escapes
    // -------------------------------------------------------------------------
    // Tagger Script recognises the following escape sequences:
    //   \$   \%   \(   \)   \,   \\   \n   \t   \uXXXX
    //
    // The unicode escape \uXXXX requires exactly four hexadecimal digits.
    escape_sequence: () => token(
      choice(
        /\\[$%()\,\\nt]/,
        /\\u[0-9a-fA-F]{4}/,
      ),
    ),

    // -------------------------------------------------------------------------
    // text – literal character sequences at the top-level expression
    // -------------------------------------------------------------------------
    // Matches one or more characters that are not special to the parser at the
    // top level.  The excluded set is: '$', '%', and '\'.
    // Whitespace and newlines are included here (they are significant output).
    text: () => token(
      /[^$%\\]+/,
    ),

    // -------------------------------------------------------------------------
    // argument_text – literal character sequences inside function arguments
    // -------------------------------------------------------------------------
    // Like `text` but also excludes '(', ')', and ',' which serve as argument
    // delimiters inside a function call.
    argument_text: () => token(
      /[^$%()\\,]+/,
    ),
  },
});
