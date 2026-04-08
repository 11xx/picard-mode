/*
 * src/scanner.c – External scanner for MusicBrainz Picard Tagger Script
 *
 * Purpose
 * -------
 * This scanner handles the single external token `_noop_content`, which
 * represents the body of a `$noop(...)` comment.  The body begins immediately
 * after the '(' that opens the noop call and ends at the matching closing ')'.
 * Nested parentheses are allowed and are consumed as part of the token content.
 *
 * The scanner emits the `_noop_content` token in a way that includes the
 * closing ')' so the grammar rule for `noop` does not need to match it
 * separately.  This simplifies the grammar and avoids any ambiguity about where
 * the noop body ends.
 *
 * Token index
 * -----------
 * The grammar declares exactly one external token:
 *
 *   externals: $ => [ $._noop_content ]   // index 0
 */

#include "tree_sitter/parser.h"
#include <stdint.h>
#include <string.h>

/* -------------------------------------------------------------------------
 * Token indices – must match the order in the grammar's `externals` array.
 * ------------------------------------------------------------------------- */
enum TokenType {
    NOOP_CONTENT = 0,
};

/* -------------------------------------------------------------------------
 * Scanner state
 * -------------------------------------------------------------------------
 * The scanner is stateless between calls – all depth tracking happens within
 * a single invocation of `scan`.  The persistent state payload is therefore
 * empty (zero bytes).
 * ------------------------------------------------------------------------- */

void *tree_sitter_taggerscript_external_scanner_create(void) {
    return NULL;
}

void tree_sitter_taggerscript_external_scanner_destroy(void *payload) {
    (void)payload;
}

unsigned tree_sitter_taggerscript_external_scanner_serialize(
    void *payload,
    char *buffer
) {
    (void)payload;
    (void)buffer;
    return 0;
}

void tree_sitter_taggerscript_external_scanner_deserialize(
    void *payload,
    const char *buffer,
    unsigned length
) {
    (void)payload;
    (void)buffer;
    (void)length;
}

/* -------------------------------------------------------------------------
 * scan – main scanner entry point
 * -------------------------------------------------------------------------
 * Called by the Tree-sitter runtime whenever the parser needs one of the
 * external tokens listed in `valid_symbols`.
 *
 * Strategy for NOOP_CONTENT
 * -------------------------
 * The grammar arranges for this scanner to be invoked immediately after the
 * literal '(' that opens the noop argument list.  The scanner therefore starts
 * reading from the character right after that '('.
 *
 * A depth counter tracks how many unmatched '(' characters have been seen.
 * The counter starts at 1 (the opening '(' was already consumed by the
 * grammar).  For every '(' encountered, depth is incremented; for every ')',
 * depth is decremented.  When depth reaches 0 the closing paren of the noop
 * call has been found.  The scanner advances past it and emits the token.
 *
 * All characters between the opening '(' and the matching closing ')' –
 * including the closing ')' itself – are consumed, making the entire span a
 * single NOOP_CONTENT token.
 *
 * Edge cases
 * ----------
 * - An empty noop body `$noop()` is valid; the scanner immediately sees ')' at
 *   depth 1, decrements to 0, and emits a zero-length (but syntactically
 *   complete) token after consuming the ')'.
 * - End-of-file inside an unterminated noop body: the scanner returns false so
 *   the parser can emit an error node rather than silently accepting the input.
 * ------------------------------------------------------------------------- */
bool tree_sitter_taggerscript_external_scanner_scan(
    void *payload,
    TSLexer *lexer,
    const bool *valid_symbols
) {
    (void)payload;

    if (!valid_symbols[NOOP_CONTENT]) {
        return false;
    }

    /*
     * Depth starts at 1 because the grammar has already matched the '(' that
     * opens the noop argument list before invoking this scanner.
     */
    int depth = 1;

    while (depth > 0) {
        if (lexer->eof(lexer)) {
            /* Unterminated noop – signal a parse error. */
            return false;
        }

        int32_t c = lexer->lookahead;

        lexer->advance(lexer, false);

        if (c == '(') {
            depth++;
        } else if (c == ')') {
            depth--;
        }
        /*
         * All other characters (including '$', '%', '\', whitespace, etc.) are
         * consumed without any special interpretation.  The noop body is opaque.
         */
    }

    /*
     * Mark the end of the token.  At this point the closing ')' has been
     * consumed by the final `advance` call inside the loop.
     */
    lexer->result_symbol = NOOP_CONTENT;
    return true;
}
