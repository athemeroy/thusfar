# Default concurrency evidence

`python -m oracle.record.concurrency --verify` starts four separate Python 3.11
processes: worker counts 1 and 12, each with hash seeds 1 and 982451653. Every
process starts from the fresh Aq source, replays the existing tape with external
network connections blocked, and must finish all 9 segments at frontier 21733.

All 154 normalized artifacts must match the committed `aq_deepseek` file hashes.
The comparison includes the complete file set, KG, paid and free usage, and
status; only the shared book recorder's documented time fields are removed.
The source fixture is checked against the corpus manifest before the runs and
must remain unchanged afterwards. The receipt also binds all production Python
modules, source file hashes, process configurations, and resulting file hashes.

The observed result is stored in `oracle/goldens/concurrency/aq.json`. CI reruns
the comparison and requires the exact committed receipt. Regression tests reject
a missing/duplicated worker/seed combination and changed or missing KG, status,
or usage artifacts.

This proves the default worker configuration only for Aq. Jekyll's lookahead
changes its prompt inputs at concurrency 12 and therefore requires additional
recordings; its single-worker tape cannot establish this property. French,
Japanese, and the Chinese long novel also remain outside this evidence. The
receipt makes no Dart implementation claim and does not close the A0 gate.
