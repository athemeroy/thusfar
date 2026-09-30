# HTTP compatibility harness

`core/tool/reference_server.dart` runs `reference/web/` against the Dart engine
for local compatibility tests. It is not a supported deployment. For the current
browser reader, see [Self-hosting](../../docs/SELF-HOSTING.md).

From `core/`:

```sh
dart pub get
YEDU_LOCAL_MODE=1 COOKIE_SECURE=0 dart run tool/reference_server.dart \
  --host 127.0.0.1 --port 18770 \
  --data /absolute/path/to/test-data --web /absolute/path/to/repository/reference/web
```

Use only local test data. Keep this HTTP harness bound to loopback; model work
requires explicit configuration and may incur provider charges.

Run the offline integration tests from `core/`:

```sh
dart test -j 1 test/http/http_server_test.dart test/ask/ask_test.dart \
  test/marginalia/marginalia_test.dart
```
