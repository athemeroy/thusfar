# UTF-16 coordinate and length audit

The reader in `web/js/reader.js` uses JavaScript text-node `.length` and `slice`, so its persisted `[start, end)` positions count UTF-16 code units. Python `len(str)` and string slices count Unicode code points. Python `len(bytes)` counts bytes. These are three distinct units for supplementary characters such as `😀` and `𠮷`.

This audit covers all **27** functions marked `正文长度疑似` in `inventory.json` and all **14** explicit production `.encode('utf-16-le')` calls in `pipeline/` and `server/`. The classification is based on the frozen Python 1.7.5 source; it is a porting contract, not a proposed change to that source.

## Inventory-tagged functions

| Function and source | Actual unit at the marked `len` site | Observable effect |
|---|---|---|
| [`judge._context`](../../pipeline/judge.py#L27) | `text` length and regex `i/j` are code points. | Local judge context; decisions can affect the graph. |
| [`judge.resolve_mentions`](../../pipeline/judge.py#L37) | `seg_text` length is a local code-point offset; `todo` length counts occurrences. Global occurrence `s/e` are converted separately to UTF-16. | Judge prompt and graph decisions. |
| [`kg.Anchor.find`](../../pipeline/kg.py#L121) | Quote and normalized-string lengths are code points. `_g` converts matched prefixes with `u16`. | Persisted graph positions use UTF-16. |
| [`kind.ordinal`](../../pipeline/kind.py#L83) | Roman-numeral token length is code points. | Work classification only. |
| [`kind.works`](../../pipeline/kind.py#L98) | `tops`, `body`, `spans`, and `starts` lengths count list items. Returned chapter bounds already use UTF-16 positions. | Graph scope can change indirectly. |
| [`llm.repair_json`](../../pipeline/llm.py#L368) | JSON input cursor length is code points. | Parsed model output. |
| [`llm.jev_free`](../../pipeline/llm.py#L659) | `text` and decoded JSON-body lengths are code points; `chunk` length counts questions. | Request limit and persisted usage/status counters. |
| [`parse.DocParser._flush`](../../pipeline/parse.py#L100) | Raw leading whitespace and raw footnote offsets are code points; cleaned prefix passes through `u16`. | Persisted `book.blocks[].fn` offsets use UTF-16. |
| [`parse.parse_epub`](../../pipeline/parse.py#L309) | Text import cap and language sample use code-point lengths; image `data` length is bytes; other lengths count entries or blocks. | Book language/structure, import rejection, image assets. |
| [`parse.parse_txt`](../../pipeline/parse.py#L710) | Text import cap and short-title threshold use code points; `blocks` length is a list count. | Persisted book and chapters. |
| [`parse._html_book`](../../pipeline/parse.py#L738) | Short-heading threshold uses code points. | Persisted MOBI chapters. |
| [`parse.parse_mobi`](../../pipeline/parse.py#L753) | `raw` length is file bytes. | Import validation. |
| [`run.Runner._text_around`](../../pipeline/run.py#L950) | `blocks` length counts blocks; text lengths are code points, but `pos - block['o']` is UTF-16. | **Mixed-unit behavior** in duplicate-person judge dossiers; see below. |
| [`run.Runner._local_job`](../../pipeline/run.py#L1579) | `hint` length is code points; `REFUSED:` is an ASCII constant. | `work/local/*.json` `hint_size` and refusal text. |
| [`app.Handler.send`](../../server/app.py#L134) | HTTP body length is bytes. | Gzip choice and `Content-Length` response header. |
| [`app.Handler.matching_snapshot`](../../server/app.py#L533) | Asset `raw` length is bytes. | Restore integrity check. |
| [`app.Handler.static`](../../server/app.py#L551) | Static body length is bytes. | Gzip choice for HTTP responses. |
| [`app._static_body`](../../server/app.py#L825) | Static body length is bytes; cache length counts entries. | Cache admission, not a text coordinate. |
| [`ask._bigrams`](../../server/ask.py#L42) | Cleaned string is split into code-point bigrams. | Question retrieval, indirectly reader-facing. |
| [`ask._book_index`](../../server/ask.py#L58) | Minimum paragraph length uses code points; `len(t.encode('utf-8'))` uses bytes; cache length counts entries. | Candidate retrieval and cache budget. |
| [`ask.who_is`](../../server/ask.py#L183) | `len(raw)//2` counts UTF-16 units; alias minimum length uses code points. | Reader-selected-word context and answer. |
| [`marginalia._page_candidates`](../../server/marginalia.py#L82) | Regex spans, trim lengths, and quote length use code points; `u16(prefix/quote)` converts output positions. `out` length counts candidates. | Persisted comment anchors and visible underlines. |
| [`marginalia.respond`](../../server/marginalia.py#L341) | Quote cap uses code points; input start/end/page bounds are UTF-16. | Visible validation and comment cache. |
| [`notebook.source_quote`](../../server/notebook.py#L13) | Raw UTF-16 byte length divided by two is code units. | Exact selected passage in persisted notes. |
| [`notebook.validate`](../../server/notebook.py#L29) | Quote/text caps use code points; start/end positions use UTF-16. | Visible limits and persisted notes. |
| [`storage.encode_assets`](../../server/storage.py#L248) | Image `raw` length is bytes. | Export manifest asset size. |
| [`storage.decode_assets`](../../server/storage.py#L265) | Base64 length counts ASCII characters; decoded `raw` length is bytes. | Restore validation. |

## Explicit UTF-16 encodings

| Source | Coordinate operation | Persisted or reader-facing |
|---|---|---|
| [`pipeline/parse.py:39`](../../pipeline/parse.py#L39) | `u16(s) = len(s.encode('utf-16-le')) // 2`; source of block, chapter, book, segment, and graph offsets. | Yes. |
| [`pipeline/llm.py:638`](../../pipeline/llm.py#L638) | Classifier instruction limit in UTF-16 units. | Indirect: batching/rejection. |
| [`pipeline/llm.py:643`](../../pipeline/llm.py#L643) | Serialized classifier request length in UTF-16 units. | Indirect: batching. |
| [`server/storage.py:173`](../../server/storage.py#L173) | Validate `block.o + UTF-16 block length <= book.len`. | Yes: restored book. |
| [`server/storage.py:181`](../../server/storage.py#L181) | Validate footnote offset against UTF-16 block length. | Yes: restored footnotes. |
| [`server/notebook.py:20`](../../server/notebook.py#L20) | Slice the source by UTF-16 byte offsets and decode strictly. | Yes: quoted note text. |
| [`server/marginalia.py:78`](../../server/marginalia.py#L78) | Slice page text by UTF-16 byte offsets, decoding with `errors='ignore'`. | Yes: comment anchors. |
| [`server/manual_entities.py:25`](../../server/manual_entities.py#L25) | Convert Python `.find` code-point start to a UTF-16 global offset. | Yes: manual entity anchor. |
| [`server/manual_entities.py:26`](../../server/manual_entities.py#L26) | Convert entity-name length to UTF-16 units for cutoff comparison. | Yes: manual entity anchor. |
| [`server/ask.py:123`](../../server/ask.py#L123) | Clip retrieval passage at UTF-16 read cutoff; ignore incomplete surrogate. | Yes: question context. |
| [`server/ask.py:158`](../../server/ask.py#L158) | Clip ranked passage at UTF-16 read cutoff; ignore incomplete surrogate. | Yes: question context. |
| [`server/ask.py:198`](../../server/ask.py#L198) | Convert block text to UTF-16 bytes for selected-word window. | Yes: visible question. |
| [`server/ask.py:213`](../../server/ask.py#L213) | Convert block text to UTF-16 bytes for exact selected word. | Yes: visible question. |
| [`server/ask.py:251`](../../server/ask.py#L251) | Clip recent-text window at UTF-16 read cutoff; ignore incomplete surrogate. | Yes: question context. |

`server/notebook.py` intentionally uses strict decoding: a selection that cuts a surrogate pair fails. `server/ask.py` and `server/marginalia.py` use `errors='ignore'`: such a cutoff silently drops the incomplete character. Dart needs both policies at their respective call sites.

## Frozen mixed-unit behavior

`Runner._text_around(pos, width)` receives a UTF-16 graph position and selects a Python string slice. Its local `at` expression adds `pos - block['o']` directly to code-point lengths of preceding blocks. At a supplementary character, the center moves right by one code point. For one block `😀ABC`, `pos=2` (UTF-16 start of `A`), and `width=2`, Python 1.7.5 returns **`AB`**. Converting `pos` to a code-point index first would produce **`😀A`**. The same shift occurs for `𠮷甲乙丙` and for an emoji after ASCII text.

This is deterministic, so A0.5 does not change Python behavior. [`utf16_offsets.json`](../../oracle/semantics/utf16_offsets.json) freezes four cases (including a BMP control). [`test_utf16_offsets.py`](../../tests/test_utf16_offsets.py) executes the Python method; [`utf16_offsets_test.dart`](../../core/test/semantics/utf16_offsets_test.dart) checks the same index expression using `PyCompat.slice` and also records the properly converted center. The Dart test is a semantic fixture; the `Runner` business function still needs its A5 port and golden comparison.

To verify the recording and both test-side interpretations, run `python3.11 -m oracle.semantics.record_utf16_offsets --check`, `python3.11 -m unittest discover -s tests -p test_utf16_offsets.py`, and, from `core/`, `dart test test/semantics/utf16_offsets_test.dart`.
