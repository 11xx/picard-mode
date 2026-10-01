;;; picard-data.el --- Central data definitions for Picard Tagger Script support  -*- lexical-binding: t -*-

;; Author: 11xx
;; Version: 2026.4.22
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5"))
;; Keywords: languages, tools, picard, musicbrainz
;; URL: https://github.com/11xx/picard-mode

;;; Commentary:

;; This file provides the central data layer shared by all Picard Tagger Script
;; editing features: syntax highlighting, Flymake diagnostics, Eldoc
;; documentation, and completion-at-point.
;;
;; Picard Tagger Script is the scripting language used by MusicBrainz Picard
;; (https://picard.musicbrainz.org/) to rename and tag audio files.  The
;; language has two main constructs:
;;
;;   $function(arg1, arg2, ...): built-in function calls
;;   %variable%: variable (tag) references
;;
;; This file defines:
;;
;;   `picard-builtin-functions': alist of the built-in functions with
;;                               metadata: min/max arity, category, argument
;;                               names, introducing version, docstring
;;   `picard-builtin-tags': alist of the built-in tags/variables with
;;                          metadata: category, introducing version,
;;                          deprecation, docstring
;;
;; and helper functions for querying these databases:
;;
;;   `picard-function-info': retrieve the plist for a function
;;   `picard-tag-info': retrieve the plist for a tag or variable
;;   `picard-function-names': list of all function names
;;   `picard-tag-names': list of all tag names
;;   `picard-data-conditional-functions': functions with whitespace-sensitive args
;;   `picard-function-conditional-args': the :conditional-args value
;;   `picard-function-conditional-arg-p': is an argument position conditional?
;;   `picard-function-args': named argument list for a function
;;
;; The data follows Picard 3.0: its script function registry
;; (picard/script/functions.py), its tag catalogue (picard/const/tags.py)
;; and the version notes of the Picard User Guide.  Entries introduced in
;; 3.0 carry `:since "3.0"', so scripts meant for Picard 2.x can avoid them.
;;
;; Design note: max-args of -1 represents unlimited (variadic) arity.

;;; Code:

(require 'cl-lib)

;;;; Function database

(defconst picard-builtin-functions
  '(("$add"
     . (:min-args 2 :max-args -1 :category "mathematical"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns the sum of all arguments."))
    ("$and"
     . (:min-args 2 :max-args -1 :category "conditional"
        :conditional-args -1
        :args ("x" "y")
        :doc "Returns true only if ALL arguments are non-empty."))
    ("$cleanmulti"
     . (:min-args 1 :max-args 1 :category "multi-value"
        :conditional-args nil
        :args ("name")
        :since "2.8"
        :doc "Removes empty elements from the multi-value variable NAME."))
    ("$copy"
     . (:min-args 2 :max-args 2 :category "assignment"
        :conditional-args nil
        :args ("new" "old")
        :since "0.9"
        :doc "Copies variable OLD to NEW, keeping multiple values intact."))
    ("$copymerge"
     . (:min-args 2 :max-args 3 :category "assignment"
        :conditional-args nil
        :args ("new" "old" "keep_duplicates")
        :since "1.0"
        :doc "Merges metadata from OLD into NEW, optionally keeping duplicates."))
    ("$countryname"
     . (:min-args 1 :max-args 2 :category "information"
        :conditional-args nil
        :args ("country_code" "translate")
        :doc "Returns the full country name from a two-letter country code."))
    ("$dateformat"
     . (:min-args 1 :max-args 3 :category "information"
        :conditional-args nil
        :args ("date" "format" "date_order")
        :since "2.7"
        :doc "Formats a date string."))
    ("$datetime"
     . (:min-args 0 :max-args 1 :category "information"
        :conditional-args nil
        :args ("format")
        :doc "Returns the current date and time."))
    ("$day"
     . (:min-args 1 :max-args 2 :category "information"
        :conditional-args nil
        :args ("date" "date_order")
        :since "2.7"
        :doc "Returns the day from a date string."))
    ("$delete"
     . (:min-args 1 :max-args 1 :category "assignment"
        :conditional-args nil
        :args ("name")
        :since "2.1"
        :doc "Unsets a tag and marks it for deletion from the file."))
    ("$delprefix"
     . (:min-args 1 :max-args -1 :category "text"
        :conditional-args nil
        :args ("text" "prefix1" "prefix2")
        :since "1.3"
        :doc "Removes the specified prefixes from the string."))
    ("$div"
     . (:min-args 2 :max-args -1 :category "mathematical"
        :conditional-args nil
        :args ("x" "y")
        :doc "Divides the first argument by all subsequent arguments."))
    ("$endswith"
     . (:min-args 2 :max-args 2 :category "conditional"
        :conditional-args nil
        :args ("text" "suffix")
        :since "1.4"
        :doc "Returns true if text ends with suffix."))
    ("$eq"
     . (:min-args 2 :max-args 2 :category "conditional"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns true if x equals y."))
    ("$eq_all"
     . (:min-args 1 :max-args -1 :category "conditional"
        :conditional-args nil
        :args ("x" "a1" "a2")
        :doc "Returns true if the first arg equals ALL subsequent args."))
    ("$eq_any"
     . (:min-args 1 :max-args -1 :category "conditional"
        :conditional-args nil
        :args ("x" "a1" "a2")
        :doc "Returns true if the first arg equals ANY subsequent arg."))
    ("$find"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("haystack" "needle")
        :since "2.3"
        :doc "Returns the position of needle in haystack, or empty if not found."))
    ("$firstalphachar"
     . (:min-args 0 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "nonalpha")
        :since "0.12"
        :doc "Returns the first character of TEXT in upper case if it is alphabetic, otherwise NONALPHA (default #)."))
    ("$firstwords"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "length")
        :since "0.12"
        :doc "Returns the complete words of TEXT that fit within LENGTH characters."))
    ("$foreach"
     . (:min-args 2 :max-args 3 :category "loop"
        :conditional-args nil
        :args ("name" "code" "separator")
        :doc "Iterates over a multi-value variable, executing code for each value."))
    ("$get"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("name")
        :doc "Returns the value of a variable by name."))
    ("$get_new"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("name")
        :since "3.0"
        :doc "Returns variable NAME from the new metadata only (from MusicBrainz or a script)."))
    ("$get_original"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("name")
        :since "3.0"
        :doc "Returns variable NAME from the file's original metadata only."))
    ("$getmulti"
     . (:min-args 2 :max-args 3 :category "multi-value"
        :conditional-args nil
        :args ("name" "index" "separator")
        :doc "Returns the item at the given index in a multi-value variable."))
    ("$gt"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args nil
        :args ("x" "y" "type")
        :doc "Returns true if x is greater than y, compared as TYPE (int, float, text, nocase or auto)."))
    ("$gte"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args nil
        :args ("x" "y" "type")
        :doc "Returns true if x is greater than or equal to y, compared as TYPE (int, float, text, nocase or auto)."))
    ("$if"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args 0
        :args ("if" "then" "else")
        :doc "If the condition IF is non-empty, returns THEN, otherwise ELSE."))
    ("$if2"
     . (:min-args 0 :max-args -1 :category "conditional"
        :conditional-args -1
        :args ("a1" "a2" "a3")
        :doc "Returns the first non-empty argument."))
    ("$in"
     . (:min-args 2 :max-args 2 :category "conditional"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns true if x contains y."))
    ("$initials"
     . (:min-args 0 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :since "0.12"
        :doc "Returns the first character of each word."))
    ("$inmulti"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args nil
        :args ("x" "y")
        :since "1.0"
        :doc "Returns true if the multi-value variable x contains exactly y as one of its values."))
    ("$is_audio"
     . (:min-args 0 :max-args 0 :category "conditional"
        :conditional-args nil
        :args nil
        :since "2.2"
        :doc "Returns true if the file is an audio file."))
    ("$is_complete"
     . (:min-args 0 :max-args 0 :category "conditional"
        :conditional-args nil
        :args nil
        :doc "Returns true if every track in the album is matched to a single file (file naming scripts only)."))
    ("$is_multi"
     . (:min-args 1 :max-args 1 :category "conditional"
        :conditional-args nil
        :args ("name")
        :since "2.7"
        :doc "Returns true if the variable contains multiple values."))
    ("$is_video"
     . (:min-args 0 :max-args 0 :category "conditional"
        :conditional-args nil
        :args nil
        :since "2.2"
        :doc "Returns true if the file is a video file."))
    ("$join"
     . (:min-args 2 :max-args 3 :category "multi-value"
        :conditional-args nil
        :args ("name" "text" "separator")
        :doc "Joins a multi-value variable with a separator phrase."))
    ("$left"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "number")
        :doc "Returns the first NUMBER characters of TEXT."))
    ("$len"
     . (:min-args 0 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :doc "Returns the length of the string."))
    ("$lenmulti"
     . (:min-args 1 :max-args 2 :category "multi-value"
        :conditional-args nil
        :args ("name" "separator")
        :doc "Returns the number of items in a multi-value variable."))
    ("$lower"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :doc "Converts text to lowercase."))
    ("$lt"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args nil
        :args ("x" "y" "type")
        :doc "Returns true if x is less than y, compared as TYPE (int, float, text, nocase or auto)."))
    ("$lte"
     . (:min-args 2 :max-args 3 :category "conditional"
        :conditional-args nil
        :args ("x" "y" "type")
        :doc "Returns true if x is less than or equal to y, compared as TYPE (int, float, text, nocase or auto)."))
    ("$map"
     . (:min-args 2 :max-args 3 :category "multi-value"
        :conditional-args nil
        :args ("name" "code" "separator")
        :doc "Applies code to each element of a multi-value variable, returns results."))
    ("$matchedtracks"
     . (:min-args 0 :max-args 0 :category "information"
        :conditional-args nil
        :args nil
        :since "0.12"
        :doc "Returns the number of matched tracks in the album (file naming scripts only)."))
    ("$max"
     . (:min-args 2 :max-args -1 :category "information"
        :conditional-args nil
        :args ("type" "x")
        :since "2.9"
        :doc "Returns the maximum of all arguments."))
    ("$min"
     . (:min-args 2 :max-args -1 :category "information"
        :conditional-args nil
        :args ("type" "x")
        :since "2.9"
        :doc "Returns the minimum of all arguments."))
    ("$mod"
     . (:min-args 2 :max-args -1 :category "mathematical"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns the modulus (remainder) of division."))
    ("$month"
     . (:min-args 1 :max-args 2 :category "information"
        :conditional-args nil
        :args ("date" "date_order")
        :since "2.7"
        :doc "Returns the month from a date string."))
    ("$mul"
     . (:min-args 2 :max-args -1 :category "mathematical"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns the product of all arguments."))
    ("$ne"
     . (:min-args 2 :max-args 2 :category "conditional"
        :conditional-args nil
        :args ("x" "y")
        :doc "Returns true if x does not equal y."))
    ("$ne_all"
     . (:min-args 1 :max-args -1 :category "conditional"
        :conditional-args nil
        :args ("x" "a1" "a2")
        :doc "Returns true if the first arg is not equal to ALL subsequent args."))
    ("$ne_any"
     . (:min-args 1 :max-args -1 :category "conditional"
        :conditional-args nil
        :args ("x" "a1" "a2")
        :doc "Returns true if the first arg is not equal to ANY subsequent arg."))
    ("$noop"
     . (:min-args 0 :max-args -1 :category "miscellaneous"
        :conditional-args nil
        :args nil
        :doc "Does nothing; returns empty string. Used for comments."))
    ("$not"
     . (:min-args 1 :max-args 1 :category "conditional"
        :conditional-args 0
        :args ("x")
        :doc "Returns true if the argument is empty."))
    ("$num"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("number" "length")
        :doc "Zero-pads NUMBER to LENGTH digits (at most 20)."))
    ("$or"
     . (:min-args 2 :max-args -1 :category "conditional"
        :conditional-args -1
        :args ("x" "y")
        :doc "Returns true if ANY argument is non-empty."))
    ("$pad"
     . (:min-args 3 :max-args 3 :category "text"
        :conditional-args nil
        :args ("text" "length" "char")
        :doc "Pads TEXT with CHAR to LENGTH characters."))
    ("$performer"
     . (:min-args 0 :max-args 2 :category "multi-value"
        :conditional-args nil
        :args ("pattern" "join")
        :since "0.10"
        :doc "Returns the performers whose performance type matches PATTERN, joined by JOIN."))
    ("$replace"
     . (:min-args 3 :max-args 3 :category "text"
        :conditional-args nil
        :args ("text" "search" "replace")
        :doc "Replaces all occurrences of SEARCH with REPLACE in TEXT."))
    ("$replacemulti"
     . (:min-args 3 :max-args 4 :category "multi-value"
        :conditional-args nil
        :args ("name" "search" "replace" "separator")
        :doc "Replaces occurrences in each element of a multi-value variable."))
    ("$reverse"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :doc "Reverses the characters in the string."))
    ("$reversemulti"
     . (:min-args 1 :max-args 2 :category "multi-value"
        :conditional-args nil
        :args ("name" "separator")
        :doc "Reverses the order of items in a multi-value variable."))
    ("$right"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "number")
        :doc "Returns the last NUMBER characters of TEXT."))
    ("$rreplace"
     . (:min-args 3 :max-args 3 :category "text"
        :conditional-args nil
        :args ("text" "pattern" "replace")
        :doc "Regex replace: replaces matches of PATTERN in TEXT with REPLACE."))
    ("$rsearch"
     . (:min-args 2 :max-args 3 :category "text"
        :conditional-args nil
        :args ("text" "pattern" "group")
        :doc "Regex search: returns capture GROUP, the first matching group, or the whole match of PATTERN in TEXT."))
    ("$set"
     . (:min-args 2 :max-args 2 :category "assignment"
        :conditional-args nil
        :args ("name" "value")
        :doc "Sets variable NAME to VALUE."))
    ("$setmulti"
     . (:min-args 2 :max-args 3 :category "assignment"
        :conditional-args nil
        :args ("name" "value" "separator")
        :since "1.0"
        :doc "Sets a multi-value variable."))
    ("$slice"
     . (:min-args 2 :max-args 4 :category "multi-value"
        :conditional-args nil
        :args ("name" "start" "end" "separator")
        :doc "Returns a slice of a multi-value variable."))
    ("$sortmulti"
     . (:min-args 1 :max-args 2 :category "multi-value"
        :conditional-args nil
        :args ("name" "separator")
        :doc "Sorts a multi-value variable."))
    ("$startswith"
     . (:min-args 2 :max-args 2 :category "conditional"
        :conditional-args nil
        :args ("text" "prefix")
        :since "1.4"
        :doc "Returns true if text starts with prefix."))
    ("$strip"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :doc "Collapses runs of whitespace in TEXT to single spaces and trims both ends."))
    ("$sub"
     . (:min-args 2 :max-args -1 :category "mathematical"
        :conditional-args nil
        :args ("x" "y")
        :doc "Subtracts all subsequent arguments from the first."))
    ("$substr"
     . (:min-args 2 :max-args 3 :category "text"
        :conditional-args nil
        :args ("text" "start" "end")
        :doc "Returns the substring from START to END index."))
    ("$swapprefix"
     . (:min-args 1 :max-args -1 :category "text"
        :conditional-args nil
        :args ("text" "prefix1" "prefix2")
        :since "1.3"
        :doc "Moves a matching prefix to the end after a comma."))
    ("$title"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :since "2.1"
        :doc "Converts text to Title Case."))
    ("$trim"
     . (:min-args 1 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "char")
        :doc "Trims leading and trailing whitespace, or CHAR when given, from TEXT."))
    ("$truncate"
     . (:min-args 2 :max-args 2 :category "text"
        :conditional-args nil
        :args ("text" "length")
        :since "0.12"
        :doc "Truncates text to LENGTH characters."))
    ("$unique"
     . (:min-args 1 :max-args 3 :category "multi-value"
        :conditional-args nil
        :args ("name" "case_sensitive" "separator")
        :doc "Removes duplicate values from a multi-value variable (case-insensitive unless CASE_SENSITIVE is set)."))
    ("$unset"
     . (:min-args 1 :max-args 1 :category "assignment"
        :conditional-args nil
        :args ("name")
        :doc "Unsets variable NAME; a trailing * matches prefixes such as performer:*."))
    ("$upper"
     . (:min-args 1 :max-args 1 :category "text"
        :conditional-args nil
        :args ("text")
        :doc "Converts text to UPPERCASE."))
    ("$while"
     . (:min-args 2 :max-args 2 :category "loop"
        :conditional-args 0
        :args ("condition" "code")
        :doc "Executes code while condition is non-empty."))
    ("$year"
     . (:min-args 1 :max-args 2 :category "information"
        :conditional-args nil
        :args ("date" "date_order")
        :since "2.7"
        :doc "Returns the year from a date string.")))
  "Alist of all Picard Tagger Script built-in functions.

Each entry has the form (NAME . PLIST) where PLIST contains:
  :min-args          Minimum number of required arguments (integer).
  :max-args          Maximum number of arguments; -1 means unlimited (variadic).
  :category          Functional category string (e.g. \"text\", \"conditional\").
  :conditional-args  Integer: 0 means only arg 0 is a condition, -1 means all
                     args are conditions, nil means not a conditional function.
  :args              List of argument name strings (index N = name for arg N),
                     as in Picard's function signatures, or nil if the
                     function takes no arguments.
  :since             Picard version that introduced the function, when the
                     Picard documentation records one; absent otherwise.
  :doc               Short documentation string.

The entries are the functions built into MusicBrainz Picard 3.0; plugins
can register more.  Arity follows Picard's own argument-count check.")

;;;; Tag / variable database

(defconst picard-builtin-tags
  '(;; ---- Basic tags (saved to audio files) ----
    ("acoustid_fingerprint"
     . (:category "basic-tag"
        :doc "AcoustID fingerprint of the audio, calculated with Chromaprint."))
    ("acoustid_id"
     . (:category "basic-tag"
        :doc "AcoustID assigned to the audio fingerprint."))
    ("albumartist"
     . (:category "basic-tag"
        :doc "The release artists, joined by their join phrases."))
    ("albumartists"
     . (:category "basic-tag" :since "3.0"
        :doc "Multi-value list of the release artists."))
    ("albumartistsort"
     . (:category "basic-tag"
        :doc "Sort name of the album artist."))
    ("album"
     . (:category "basic-tag"
        :doc "The title of the release (album)."))
    ("albumsort"
     . (:category "basic-tag"
        :doc "Sort name of the album title."))
    ("arranger"
     . (:category "basic-tag" :since "0.10"
        :doc "Arrangers associated with the track."))
    ("artist"
     . (:category "basic-tag"
        :doc "The track artists, joined by their join phrases."))
    ("artists"
     . (:category "basic-tag" :since "1.3"
        :doc "Multi-value list of the track artists."))
    ("artistsort"
     . (:category "basic-tag"
        :doc "Sort name of the primary artist."))
    ("asin"
     . (:category "basic-tag"
        :doc "Amazon Standard Identification Number."))
    ("barcode"
     . (:category "basic-tag"
        :doc "Barcode of the release."))
    ("bpm"
     . (:category "basic-tag"
        :doc "Beats per minute of the track."))
    ("catalognumber"
     . (:category "basic-tag"
        :doc "Catalog number assigned by the label."))
    ("comment"
     . (:category "basic-tag"
        :doc "Disambiguation comment of the release (e.g. Deluxe version with 2 bonus tracks)."))
    ("compilation"
     . (:category "basic-tag" :since "1.3"
        :doc "Set to 1 for Various Artists releases, otherwise empty."))
    ("composer"
     . (:category "basic-tag"
        :doc "Composer of the work."))
    ("composersort"
     . (:category "basic-tag"
        :doc "Sort name of the composer."))
    ("conductor"
     . (:category "basic-tag"
        :doc "Conductor of the performance."))
    ("copyright"
     . (:category "basic-tag"
        :doc "Copyright notice for the recording."))
    ("date"
     . (:category "basic-tag"
        :doc "Date the release was issued (YYYY-MM-DD or partial)."))
    ("director"
     . (:category "basic-tag" :since "2.6"
        :doc "Director associated with the release (video releases)."))
    ("discid"
     . (:category "basic-tag"
        :doc "Disc ID of the disc in the FreeDB database."))
    ("discnumber"
     . (:category "basic-tag"
        :doc "Number of the disc within the release."))
    ("discsubtitle"
     . (:category "basic-tag"
        :doc "Subtitle of the individual disc."))
    ("djmixer"
     . (:category "basic-tag" :since "0.9"
        :doc "Name of the DJ who mixed the release."))
    ("encodedby"
     . (:category "basic-tag"
        :doc "Name of the person or software that encoded the file."))
    ("encodersettings"
     . (:category "basic-tag"
        :doc "Encoder settings used when creating the file."))
    ("engineer"
     . (:category "basic-tag"
        :doc "Name of the recording engineer."))
    ("gapless"
     . (:category "basic-tag"
        :doc "Indicates gapless playback (1 or 0)."))
    ("genre"
     . (:category "basic-tag" :since "2.1"
        :doc "Genre of the track."))
    ("grouping"
     . (:category "basic-tag"
        :doc "Genre grouping associated with the track."))
    ("isrc"
     . (:category "basic-tag" :since "0.12"
        :doc "International Standard Recording Code."))
    ("itunes_cddb_1"
     . (:category "basic-tag" :since "3.0"
        :doc "iTunes CD identifier derived from the track count and lengths."))
    ("key"
     . (:category "basic-tag"
        :doc "Musical key of the track."))
    ("label"
     . (:category "basic-tag"
        :doc "Name of the record label."))
    ("language"
     . (:category "basic-tag" :since "0.10"
        :doc "Lyrics language of the work (ISO 639-3 code)."))
    ("license"
     . (:category "basic-tag" :since "1.0"
        :doc "License under which the track is released."))
    ("lyricist"
     . (:category "basic-tag"
        :doc "Author of the lyrics."))
    ("lyrics"
     . (:category "basic-tag"
        :doc "Full lyrics of the track."))
    ("media"
     . (:category "basic-tag"
        :doc "Media type of the release (e.g. CD, Vinyl)."))
    ("mixer"
     . (:category "basic-tag" :since "0.9"
        :doc "Name of the mixing engineer."))
    ("mood"
     . (:category "basic-tag"
        :doc "Mood or atmosphere of the track."))
    ("movement"
     . (:category "basic-tag"
        :doc "Name of the movement within a multi-movement work."))
    ("movementnumber"
     . (:category "basic-tag"
        :doc "Number of the movement within the work."))
    ("movementtotal"
     . (:category "basic-tag"
        :doc "Total number of movements in the work."))
    ("musicbrainz_albumartistid"
     . (:category "basic-tag"
        :doc "MusicBrainz ID of the album artist."))
    ("musicbrainz_albumid"
     . (:category "basic-tag"
        :doc "MusicBrainz Release ID."))
    ("musicbrainz_artistid"
     . (:category "basic-tag"
        :doc "MusicBrainz Artist ID."))
    ("musicbrainz_composerid"
     . (:category "basic-tag" :since "3.0"
        :doc "MusicBrainz Artist ID for the composer."))
    ("musicbrainz_discid"
     . (:category "basic-tag" :since "0.12"
        :doc "MusicBrainz Disc ID."))
    ("musicbrainz_originalalbumid"
     . (:category "basic-tag"
        :doc "MusicBrainz Release ID of the original release."))
    ("musicbrainz_originalartistid"
     . (:category "basic-tag"
        :doc "MusicBrainz Artist ID of the original artist."))
    ("musicbrainz_recordingid"
     . (:category "basic-tag"
        :doc "MusicBrainz Recording ID."))
    ("musicbrainz_releasegroupid"
     . (:category "basic-tag"
        :doc "MusicBrainz Release Group ID."))
    ("musicbrainz_trackid"
     . (:category "basic-tag"
        :doc "MusicBrainz Track ID."))
    ("musicbrainz_workid"
     . (:category "basic-tag"
        :doc "MusicBrainz Work ID."))
    ("musicip_fingerprint"
     . (:category "basic-tag"
        :doc "MusicIP audio fingerprint."))
    ("musicip_puid"
     . (:category "basic-tag"
        :doc "MusicIP PUID identifier."))
    ("originalalbum"
     . (:category "basic-tag"
        :doc "Title of the original release."))
    ("originalartist"
     . (:category "basic-tag"
        :doc "Name of the original performing artist."))
    ("originaldate"
     . (:category "basic-tag"
        :doc "Original release date (YYYY-MM-DD or partial)."))
    ("originalfilename"
     . (:category "basic-tag"
        :doc "Original filename of the audio file."))
    ("originalyear"
     . (:category "basic-tag"
        :doc "Year of the original release."))
    ("performer"
     . (:category "basic-tag"
        :doc "Performers of a type, referenced as %performer:TYPE% (e.g. performer:vocal)."))
    ("podcast"
     . (:category "basic-tag"
        :doc "Indicates whether the file is a podcast (1 or 0)."))
    ("podcasturl"
     . (:category "basic-tag"
        :doc "URL of the podcast feed."))
    ("producer"
     . (:category "basic-tag"
        :doc "Name of the producer."))
    ("r128_album_gain"
     . (:category "basic-tag"
        :doc "Album gain from EBU R 128 analysis."))
    ("r128_track_gain"
     . (:category "basic-tag"
        :doc "Track gain from EBU R 128 analysis."))
    ("releasecountry"
     . (:category "basic-tag"
        :doc "Country in which the release was issued."))
    ("releasedate"
     . (:category "basic-tag" :since "2.9"
        :doc "Date of this specific release event."))
    ("releasestatus"
     . (:category "basic-tag"
        :doc "MusicBrainz release status (Official, Promotional, etc.)."))
    ("releasetype"
     . (:category "basic-tag"
        :doc "Types of the release group (Album, Single, Live, etc.)."))
    ("remixer"
     . (:category "basic-tag"
        :doc "Name of the remixer."))
    ("replaygain_album_gain"
     . (:category "basic-tag"
        :doc "ReplayGain album gain adjustment in dB."))
    ("replaygain_album_peak"
     . (:category "basic-tag"
        :doc "ReplayGain album peak amplitude."))
    ("replaygain_album_range"
     . (:category "basic-tag"
        :doc "ReplayGain album dynamic range in LU."))
    ("replaygain_reference_loudness"
     . (:category "basic-tag"
        :doc "ReplayGain reference loudness in dBFS."))
    ("replaygain_track_gain"
     . (:category "basic-tag"
        :doc "ReplayGain track gain adjustment in dB."))
    ("replaygain_track_peak"
     . (:category "basic-tag"
        :doc "ReplayGain track peak amplitude."))
    ("replaygain_track_range"
     . (:category "basic-tag"
        :doc "ReplayGain track dynamic range in LU."))
    ("script"
     . (:category "basic-tag" :since "0.10"
        :doc "Writing script used in the release (e.g. Latin, Cyrillic)."))
    ("show"
     . (:category "basic-tag"
        :doc "Name of the TV show or podcast series."))
    ("showmovement"
     . (:category "basic-tag"
        :doc "Indicates whether to show the movement number and name (1 or 0)."))
    ("showsort"
     . (:category "basic-tag"
        :doc "Sort name of the show."))
    ("subtitle"
     . (:category "basic-tag"
        :doc "Subtitle of the track."))
    ("syncedlyrics"
     . (:category "basic-tag" :since "3.0"
        :doc "Time-synchronized lyrics in LRC format."))
    ("title"
     . (:category "basic-tag"
        :doc "Title of the track."))
    ("titlesort"
     . (:category "basic-tag"
        :doc "Sort name of the track title."))
    ("totaldiscs"
     . (:category "basic-tag"
        :doc "Total number of discs in the release."))
    ("totaltracks"
     . (:category "basic-tag"
        :doc "Total number of tracks on the disc."))
    ("tracknumber"
     . (:category "basic-tag"
        :doc "Track number on the disc."))
    ("website"
     . (:category "basic-tag"
        :doc "Official website of the artist."))
    ("work"
     . (:category "basic-tag" :since "1.3"
        :doc "Title of the musical work."))
    ("writer"
     . (:category "basic-tag" :since "1.0"
        :doc "Name of the writer of the work."))
    ;; ---- Hidden variables (internal, not saved to files) ----
    ("_absolutetracknumber"
     . (:category "hidden-variable" :since "1.3"
        :doc "Absolute track number across all discs of the release."))
    ("_albumartistcomment"
     . (:category "hidden-variable" :since "3.0"
        :doc "Disambiguation comment of the album artist, when there is exactly one."))
    ("_albumartists"
     . (:category "hidden-variable" :since "1.3"
        :deprecated "Retained for backward compatibility; use %albumartists% instead."
        :doc "Multi-value list of all album artists."))
    ("_albumartists_comments"
     . (:category "hidden-variable" :since "3.0"
        :doc "Disambiguation comments of all album artists, in artist order."))
    ("_albumartists_countries"
     . (:category "hidden-variable" :since "3.0"
        :doc "Countries associated with each album artist."))
    ("_albumartists_sort"
     . (:category "hidden-variable" :since "1.3"
        :doc "Sort names of all album artists as a multi-value list."))
    ("_artistcomment"
     . (:category "hidden-variable" :since "3.0"
        :doc "Disambiguation comment of the track artist, when there is exactly one."))
    ("_artists_comments"
     . (:category "hidden-variable" :since "3.0"
        :doc "Disambiguation comments of all track artists, in artist order."))
    ("_artists_countries"
     . (:category "hidden-variable" :since "3.0"
        :doc "Countries associated with each track artist."))
    ("_artists_sort"
     . (:category "hidden-variable" :since "1.3"
        :doc "Sort names of all track artists as a multi-value list."))
    ("_bitrate"
     . (:category "hidden-variable"
        :doc "Bitrate of the audio file in kbps."))
    ("_bits_per_sample"
     . (:category "hidden-variable"
        :doc "Bit depth (bits per sample) of the audio file."))
    ("_broadcast_date"
     . (:category "hidden-variable"
        :doc "Broadcast date for radio or TV recordings."))
    ("_channels"
     . (:category "hidden-variable"
        :doc "Number of audio channels (1 = mono, 2 = stereo, etc.)."))
    ("_datatrack"
     . (:category "hidden-variable" :since "1.3.1"
        :doc "Set to 1 if the track is a data track, otherwise empty."))
    ("_dirname"
     . (:category "hidden-variable" :since "1.1"
        :doc "Directory name containing the audio file."))
    ("_discpregap"
     . (:category "hidden-variable" :since "1.4"
        :doc "Set to 1 if the disc has a pregap track, otherwise empty."))
    ("_extension"
     . (:category "hidden-variable" :since "0.9"
        :doc "File extension of the audio file (e.g. flac, mp3)."))
    ("_file_created_timestamp"
     . (:category "hidden-variable" :since "2.9"
        :doc "File creation time as YYYY-MM-DD HH:MM:SS, as reported by the file system."))
    ("_file_modified_timestamp"
     . (:category "hidden-variable" :since "2.9"
        :doc "File modification time as YYYY-MM-DD HH:MM:SS, as reported by the file system."))
    ("_filename"
     . (:category "hidden-variable" :since "1.1"
        :doc "Base filename of the audio file without extension."))
    ("_filepath"
     . (:category "hidden-variable" :since "3.0"
        :doc "Full absolute path of the audio file."))
    ("_filesize"
     . (:category "hidden-variable" :since "3.0"
        :doc "File size in bytes."))
    ("_folksonomy_tags"
     . (:category "hidden-variable" :since "3.0"
        :doc "Community-submitted folksonomy tags from MusicBrainz."))
    ("_format"
     . (:category "hidden-variable"
        :doc "Audio format description string (e.g. FLAC, MPEG-1 Audio)."))
    ("_genres"
     . (:category "hidden-variable" :since "3.0"
        :doc "Multi-value list of genres from MusicBrainz."))
    ("_iswc"
     . (:category "hidden-variable" :since "3.0"
        :doc "International Standard Musical Work Code (ISWC) of the work."))
    ("_length"
     . (:category "hidden-variable"
        :doc "Track length as minutes:seconds."))
    ("_lyricistsort"
     . (:category "hidden-variable" :since "2.9"
        :doc "Sort name of the lyricist."))
    ("_multiartist"
     . (:category "hidden-variable" :since "1.3"
        :doc "Set to 1 if not all tracks of the release have the same primary artist, otherwise empty."))
    ("_musicbrainz_discids"
     . (:category "hidden-variable"
        :doc "All disc IDs associated with this release medium."))
    ("_musicbrainz_tracknumber"
     . (:category "hidden-variable"
        :doc "MusicBrainz track number including prefix letters."))
    ("_paddedtracknumber"
     . (:category "hidden-variable"
        :doc "Track number zero-padded to the width of the track count (from the Padded plugin, not Picard itself)."))
    ("_performance_attributes"
     . (:category "hidden-variable" :since "1.3"
        :doc "Attributes of the performance relationship (e.g. live, cover)."))
    ("_pregap"
     . (:category "hidden-variable" :since "1.3.1"
        :doc "Set to 1 if the track is a pregap track, otherwise empty."))
    ("_primaryreleasetype"
     . (:category "hidden-variable"
        :doc "Primary MusicBrainz release group type (Album, Single, etc.)."))
    ("_rating"
     . (:category "hidden-variable"
        :doc "MusicBrainz user rating of the recording (0-5)."))
    ("_recording_firstreleasedate"
     . (:category "hidden-variable" :since "2.6"
        :doc "Date of the first known release of this recording."))
    ("_recording_series"
     . (:category "hidden-variable" :since "2.9"
        :doc "Series the recording belongs to."))
    ("_recording_seriescomment"
     . (:category "hidden-variable" :since "2.9"
        :doc "Disambiguation comment for the recording series."))
    ("_recording_seriesid"
     . (:category "hidden-variable" :since "2.9"
        :doc "MusicBrainz ID of the recording series."))
    ("_recording_seriesnumber"
     . (:category "hidden-variable" :since "2.9"
        :doc "Number of the recording within its series."))
    ("_recordingcomment"
     . (:category "hidden-variable" :since "0.15"
        :doc "Disambiguation comment for the recording."))
    ("_recordingtitle"
     . (:category "hidden-variable"
        :doc "Title of the recording as stored in MusicBrainz."))
    ("_release_series"
     . (:category "hidden-variable" :since "2.9"
        :doc "Series the release belongs to."))
    ("_release_seriescomment"
     . (:category "hidden-variable" :since "2.9"
        :doc "Disambiguation comment for the release series."))
    ("_release_seriesid"
     . (:category "hidden-variable" :since "2.9"
        :doc "MusicBrainz ID of the release series."))
    ("_release_seriesnumber"
     . (:category "hidden-variable" :since "2.9"
        :doc "Number of the release within its series."))
    ("_releaseannotation"
     . (:category "hidden-variable" :since "2.6"
        :doc "Free-text annotation attached to the release in MusicBrainz."))
    ("_releasecomment"
     . (:category "hidden-variable" :since "0.15"
        :doc "Disambiguation comment for the release."))
    ("_releasecountries"
     . (:category "hidden-variable" :since "2.3.1"
        :doc "Multi-value list of all release event countries."))
    ("_releasegroup"
     . (:category "hidden-variable"
        :doc "Title of the MusicBrainz release group."))
    ("_releasegroup_firstreleasedate"
     . (:category "hidden-variable" :since "2.6"
        :doc "Date of the first release in this release group."))
    ("_releasegroup_series"
     . (:category "hidden-variable" :since "2.9"
        :doc "Series the release group belongs to."))
    ("_releasegroup_seriescomment"
     . (:category "hidden-variable" :since "2.9"
        :doc "Disambiguation comment for the release group series."))
    ("_releasegroup_seriesid"
     . (:category "hidden-variable" :since "2.9"
        :doc "MusicBrainz ID of the release group series."))
    ("_releasegroup_seriesnumber"
     . (:category "hidden-variable" :since "2.9"
        :doc "Number of the release group within its series."))
    ("_releasegroupcomment"
     . (:category "hidden-variable"
        :doc "Disambiguation comment for the release group."))
    ("_releaselanguage"
     . (:category "hidden-variable" :since "0.10"
        :doc "Language of the release (ISO 639-3 code)."))
    ("_sample_rate"
     . (:category "hidden-variable"
        :doc "Sample rate of the audio file in Hz."))
    ("_secondaryreleasetype"
     . (:category "hidden-variable"
        :doc "Secondary MusicBrainz release type (Compilation, Live, etc.)."))
    ("_silence"
     . (:category "hidden-variable"
        :doc "Set to 1 if the track title is \"[silence]\", otherwise empty."))
    ("_totalalbumtracks"
     . (:category "hidden-variable"
        :doc "Total number of tracks across all discs in the release."))
    ("_video"
     . (:category "hidden-variable"
        :doc "Set to 1 if the track is a video, otherwise empty."))
    ("_work_series"
     . (:category "hidden-variable" :since "2.9"
        :doc "Series the work belongs to."))
    ("_work_seriescomment"
     . (:category "hidden-variable" :since "2.9"
        :doc "Disambiguation comment for the work series."))
    ("_work_seriesid"
     . (:category "hidden-variable" :since "2.9"
        :doc "MusicBrainz ID of the work series."))
    ("_work_seriesnumber"
     . (:category "hidden-variable" :since "2.9"
        :doc "Number of the work within its series."))
    ("_workcomment"
     . (:category "hidden-variable" :since "2.7"
        :doc "Disambiguation comment for the work."))
    ("_writersort"
     . (:category "hidden-variable" :since "2.9"
        :doc "Sort name of the writer.")))
  "Alist of all Picard Tagger Script built-in tags and hidden variables.

Each entry has the form (NAME . PLIST) where PLIST contains:
  :category   Either \"basic-tag\" (saved to audio files) or
              \"hidden-variable\" (internal, underscore-prefixed).
  :since      Picard version that introduced the entry, when the Picard
              documentation records one; absent otherwise.
  :deprecated Present on entries Picard keeps only for backward
              compatibility: a string naming the replacement.
  :doc        Short documentation string.

Basic tags correspond to standard audio metadata fields written to files.
Hidden variables are values Picard provides at script evaluation time;
they begin with an underscore and are never written to the audio file.")

;;;; Helper functions

(defun picard-function-info (name)
"Return the property list for the Picard function NAME, or nil if unknown.

NAME should be a string including the leading dollar sign, e.g. \"$if\".
The returned plist contains :min-args, :max-args, :category,
:conditional-args, :args, and :doc keys, and :since when known.

See also `picard-function-conditional-arg-p' and `picard-function-args'
for convenient accessors to the :conditional-args and :args fields."
  (cdr (assoc name picard-builtin-functions)))

(defun picard-tag-info (name)
  "Return the property list for the Picard tag or variable NAME, or nil.

NAME should be a bare string without percent signs, e.g. \"artist\" or
\"_filename\".  The returned plist contains :category and :doc keys, and
:since and :deprecated when known."
  (cdr (assoc name picard-builtin-tags)))

(defun picard-function-names ()
  "Return a list of all Picard built-in function name strings.

Each element includes the leading dollar sign, e.g. \"$if\", \"$set\".
The list is derived from `picard-builtin-functions'."
  (mapcar #'car picard-builtin-functions))

(defun picard-tag-names ()
  "Return a list of all Picard built-in tag and variable name strings.

Each element is the bare name without percent delimiters, e.g. \"artist\",
\"_filename\".  The list is derived from `picard-builtin-tags'."
  (mapcar #'car picard-builtin-tags))

(defun picard-data-conditional-functions ()
  "Return the list of Picard function names that have conditional arguments.

These are functions whose argument whitespace is checked by the Flymake
whitespace scanner because leading spaces in those arguments can change
truthiness.  Currently: $if, $if2, $and, $or, $not, $while."
  (cl-loop for (name . info) in picard-builtin-functions
           when (plist-get info :conditional-args)
           collect name))

(defun picard-function-conditional-args (func-name)
  "Return the conditional-args value for FUNC-NAME.

Returns 0 if only argument 0 is a condition, -1 if all arguments are
conditions, or nil if FUNC-NAME is not a conditional function."
  (let ((info (picard-function-info func-name)))
    (when info
      (plist-get info :conditional-args))))

(defun picard-function-conditional-arg-p (func-name index)
  "Return non-nil if argument INDEX of FUNC-NAME is a condition position.

INDEX is zero-based.  Returns non-nil when INDEX falls within the
conditional-args range for FUNC-NAME (0 means only arg 0 is conditional,
-1 means all args are conditional)."
  (let ((cond-args (picard-function-conditional-args func-name)))
    (cond
     ((eq cond-args 0) (= index 0))
     ((eq cond-args -1) t)
     (t nil))))

(defun picard-function-args (func-name)
  "Return the argument name list for FUNC-NAME, or nil if none defined.

The returned list has index N corresponding to argument N.  Returns nil
when FUNC-NAME has no named parameters defined."
  (let ((info (picard-function-info func-name)))
    (when info
      (plist-get info :args))))

(provide 'picard-data)
;;; picard-data.el ends here
