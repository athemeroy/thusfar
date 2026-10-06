# Native reader text purification

The reader's **More → 文本净化** opens local literal rules. A text selection's
**净化** action starts a rule using its original source quote, scoped to the
current book. Rules can be edited, disabled, deleted or moved up/down. The editor
previews the original fragments of the page that opened it, never future text.
The all-books switch is explicit. A disabled rule's editor previews its enabled
effect but saves it disabled.

## Semantics and safety

- Match immutable source text left to right, independently within each text
  paragraph or heading. At the same source position the earlier rule wins.
  Replacement output is never re-matched, so order does not create cascades.
- Literal text only. Regex syntax is escaped; no executable rules, scripts,
  network requests, credential access, or model calls are involved.
- Empty replacement deletes the matched display text. Empty patterns, line
  breaks, malformed UTF-16, more than 64 rules, or fields over 512 UTF-16 units
  are rejected. Replacement length is capped at 8× its match, bounding output.
- `PurifiedText` maps display UTF-16 positions back to the immutable original.
  Replacement characters cite the complete original matched range; deleted
  characters have no display span. Selections crossing a deletion quote the
  original intervening text. Emoji surrogate pairs are never selected by half.
- Pagination, rendering, highlights, pointer hit-testing, selection handles and
  accessibility clipping use the same mapped text. Page and knowledge cutoffs,
  notes, citations and saved progress stay in original-source coordinates.
- Rule changes invalidate layout without writing progress; the retained source
  anchor is reused when rules are edited or switched off. A replacement split
  across pages shares its source range, so an exact intra-replacement display
  position is not separately persisted. Reopening or jumping to that source
  anchor starts at its first display page; sequential page turns remain index-based.
- An entirely hidden chapter still has one navigable empty page. Its cutoff
  does not advance into hidden text or the next chapter, and page estimates stay
  finite. No `book.json`, generated knowledge, source search or note data changes.

## Storage and portability

Rules use atomic writes to `text-purification.json` at the library root. A damaged
store remains on disk, displays an error in the rule manager, and is not silently
overwritten. Failed writes keep the last in-memory rules.

**导出规则** creates a versioned `thusfar-purification.json` containing the current
book's rules plus global rules. **导入规则** validates and shows a confirmation
preview, warns about global rules, rebinds book-scoped rules to the current book,
and appends new rules in file order. Exact duplicates are skipped; existing rules
are never overwritten. Both serialized input and streamed file reads are limited
to 512 KiB, including JSON escaping and unknown file sizes. The format contains rule text, scope and enabled state,
not book content or credentials.

This first implementation is native-reader only. It does not implement Legado
rule compatibility, regex, cross-paragraph replacements,
or Web reader transforms. Book-scoped rules now travel with single-book JSON
and WebDAV; whole-library ZIP additionally carries global rules with explicit
restore consent. See [portable reader customizations](READER-CUSTOMIZATIONS.md)
for source validation, precedence, conflict and rollback semantics. Standalone
rule export remains available.

## Verification

`flutter test test/text_purification_test.dart` covers literal ordering/deletion,
length changes, emoji boundaries, source quotes/notes, original-source progress,
empty chapters, corruption and portable import, native long press and handle
movement, editing/toggling/deletion/cancellation, semantic clipping, and a small
phone at 2× text scale. Run the existing reader/selection and backup suites too.
Real Android selection and document-provider import/export still need device
checks. APK building/signing remains on the authorized original-signature host.
