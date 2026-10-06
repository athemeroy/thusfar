# Portable native reader customizations

Book JSON and WebDAV snapshots carry a versioned `reader_customizations`
payload when the book has literal purification rules, a TXT directory sidecar,
or global rules that the export must disclose as omitted. The canonical book,
source coordinates, notes, progress and chapter-indexed AI files are unchanged.

## Scope and consent

- Single-book exports contain only rules scoped to that exact source book. They
  explicitly omit global rules. Use the whole-library ZIP or **导出规则** to save
  global rules; a single-book restore does not promise identical appearance if
  the original reader depended on global rules.
- Whole-library ZIP includes a checksum-verified `customizations.json` member:
  global rules plus rules belonging to books in that archive, in their original
  interleaved order, with stable IDs and enabled states. Recycle-bin books and
  their scoped rules are outside the current shelf backup, as before.
- **使用备份设置** explicitly permits the native whole-library restore to add
  global rules, which affect all books. **保留当前设置** restores only the per-book
  rules and directories, leaving globals alone. Cancel publishes nothing.
- Portable native settings also include the nine-zone tap layout, paragraph
  spacing and first-line indent. Missing keys in older archives preserve the
  current preferences; these settings change only with settings consent.
- Existing local rule order and enabled choices take precedence. New semantic
  rules append in archive order; matches against existing local rules are skipped.
  Distinct incoming-only IDs retain their complete enabled states and order. The same rule ID with
  different text/scope is a conflict. Applying an archive to a fresh library
  reproduces its complete global/book precedence. Reimport is idempotent.
- An absent local directory can receive a verified sidecar. An identical one is
  retained; a different local sidecar, including an explicit reset, is reported
  as a conflict and is never overwritten.
- The standalone **导出规则 / 导入规则** flow remains available and deliberately
  permits a user to rebind book rules to another book after its separate preview.
  Backup restore does not perform that arbitrary rebinding.

## Identity, limits and compatibility

Version 1 fingerprints use SHA-256 of canonical JSON containing immutable
`len`, `blocks`, canonical `chapters` (excluding generated `spoil` and
`spoilSource` verdicts) and source `notes`. Mutable book display metadata and JSON
object-key ordering do not affect the fingerprint. A directory is accepted only
for verified TXT provenance; every title and UTF-16 offset must match its
original complete source block. A destination ID can change only after the
existing same-book importer verifies the source and resolves the local book.

Rules use the existing 64-rule, 512-character, 512-KiB bounds. Directory payloads
retain the 10,000-heading, 120-character heading and 4-MiB encoded limits.
Unknown versions, corrupt rules, unexpected fields, foreign book scopes, stale
fingerprints and invalid offsets fail before publication. Damaged local data is
not silently omitted from an export. No credentials, model calls, regex scripts
or executable rules are introduced.

The established `yedu-book/1`, `yedu-book/2`, `thusfar-web-backup-v1` and
`thusfar-library/1` formats remain readable. Customizations are additive,
individually versioned fields/a manifest member. Older app versions may reject
new ZIP members or ignore new single-book fields; use the current version when
restoring these customizations. Old backups with no customization data leave
existing local reader customizations untouched.

## Failures and Web transfers

Native single-book merges include customization writes in the existing durable
rollback journal. A first import stages its sidecar alongside the book and
journals root rule/progress publication; failed publication rolls it back. An
interrupted committed-directory transaction is recovered at startup. Hidden
unpublished staging directories are not treated as restored books. An open
reader refreshes changed rules and directory metadata on library updates; a
stale rule editor cannot overwrite a rule store changed by a restore.

Whole-library restore retains the established per-book outcome model: completed
books can remain when another book fails, and every failure is reported. Full
rule settings are preflighted before book writes and committed only after all
books succeed. If saving the final rule store fails, its previous atomic file
remains, restored books are reported explicitly, and the archive can be retried.
This is not an all-or-nothing replacement of the user's library.

Web validates and preserves native customizations as transfer metadata; Web
rendering does not apply purification or corrected TXT directories. Identical
native payloads merge; different opaque payloads conservatively conflict.
Whole-library global metadata is retained only with the existing explicit
settings consent. Web re-export filters scoped rules for removed source books
without reassigning them to another book, preserves globals and rule order, and
rejects damaged or stale retained metadata instead of dropping it silently.
