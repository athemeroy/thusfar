// Shared only by pages in this browser tab. It is intentionally never written
// to IndexedDB, localStorage, sessionStorage, a backup, or a URL.
import 'web_ai_engine.dart';

class WebModelSession {
  WebModelSession._();

  static final WebModelSession current = WebModelSession._();

  WebAiConfig? _config;

  WebAiConfig? get config => _config;

  /// Call only after the user explicitly accepts the displayed endpoint.
  void set(WebAiConfig config) => _config = config;

  void clear() => _config = null;
}
