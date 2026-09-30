# Ask fixtures

`generate_reference.py` records the Python reference with local model fixtures.
The output pins the source SHA-256 and includes complete requests and ordered
events. It makes no network calls. Review fixture changes before committing.

From the repository root:

```sh
python3 core/test/ask/generate_reference.py
cd core
dart test -j 1 test/ask/ask_test.dart
```

Flutter interaction checks are in `app/test/ask_sheet_test.dart`.
