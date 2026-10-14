import 'dart:async';

import 'package:flutter/material.dart';

import 'web_app.dart';
import 'web_storage.dart';

/// A browser route contains only a local book ID. Text and model configuration
/// never appear in the URL. Flutter's default hash strategy keeps static hosts
/// and custom deployment base paths working without server rewrite rules.
class WebReadingRoute {
  const WebReadingRoute([this.bookId]);

  final String? bookId;

  static WebReadingRoute fromUri(Uri uri) {
    final List<String> parts = uri.pathSegments;
    if (parts.length == 2 &&
        parts.first == 'read' &&
        RegExp(r'^[0-9a-f]{24}$').hasMatch(parts.last)) {
      return WebReadingRoute(parts.last);
    }
    return const WebReadingRoute();
  }

  Uri get uri => Uri(path: bookId == null ? '/' : '/read/$bookId');
}

class WebReadingRouteParser extends RouteInformationParser<WebReadingRoute> {
  const WebReadingRouteParser();

  @override
  Future<WebReadingRoute> parseRouteInformation(
    RouteInformation routeInformation,
  ) => Future<WebReadingRoute>.value(
    WebReadingRoute.fromUri(routeInformation.uri),
  );

  @override
  RouteInformation restoreRouteInformation(WebReadingRoute configuration) =>
      RouteInformation(uri: configuration.uri);
}

class WebReadingRouter extends RouterDelegate<WebReadingRoute>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<WebReadingRoute> {
  WebReadingRouter() : _library = WebLibrary.open();

  Future<WebLibrary> _library;
  final ValueNotifier<int> _shelfRefresh = ValueNotifier<int>(0);
  final Map<String, ({WebLibrary library, WebReadingState state})> _sessions =
      {};
  String? _bookId;
  bool _disposed = false;
  int _routeGeneration = 0;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  WebReadingRoute get currentConfiguration => WebReadingRoute(_bookId);

  void _open(String id) {
    if (_bookId == id) return;
    _routeGeneration++;
    _bookId = id;
    notifyListeners();
  }

  Future<void> _flushReader() async {
    final session = _sessions[_bookId];
    if (session == null || _bookId == null) return;
    try {
      await session.library.saveState(_bookId!, session.state);
    } on Object {
      final BuildContext? context = navigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('当前阅读位置暂未保存，请检查浏览器存储空间。')),
        );
      }
    }
  }

  void _shelf() {
    if (_bookId == null) return;
    _routeGeneration++;
    final Future<void> flushed = _flushReader();
    _sessions.clear();
    _bookId = null;
    notifyListeners();
    unawaited(
      flushed.then((_) {
        if (!_disposed) _shelfRefresh.value++;
      }),
    );
  }

  void _retryLibrary() {
    final Future<WebLibrary> previous = _library;
    _library = WebLibrary.open();
    _sessions.clear();
    unawaited(
      previous.then<void>(
        (WebLibrary library) => library.close(),
        onError: (Object error, StackTrace trace) {},
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> setNewRoutePath(WebReadingRoute route) async {
    final int generation = ++_routeGeneration;
    if (_bookId == route.bookId) return;
    final bool leftReader = _bookId != null;
    if (leftReader) await _flushReader();
    if (_disposed || generation != _routeGeneration) return;
    _bookId = route.bookId;
    _sessions.clear();
    if (leftReader && route.bookId == null) _shelfRefresh.value++;
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    final String? bookId = _bookId;
    return Navigator(
      key: navigatorKey,
      pages: <Page<void>>[
        MaterialPage<void>(
          key: const ValueKey<String>('web-shelf'),
          child: WebShelf(
            library: _library,
            onOpenBook: _open,
            refreshSignal: _shelfRefresh,
            onRetryLibrary: _retryLibrary,
          ),
        ),
        if (bookId != null)
          MaterialPage<void>(
            key: ValueKey<String>('web-reader:$bookId'),
            child: _LocalBookRoute(
              bookId: bookId,
              library: _library,
              onRetryLibrary: _retryLibrary,
              onReady: (session) {
                if (!_disposed && bookId == _bookId) {
                  _sessions.clear();
                  _sessions[bookId] = session;
                }
              },
            ),
          ),
      ],
      onDidRemovePage: (Page<Object?> page) {
        if (page.key == ValueKey<String>('web-reader:$_bookId')) _shelf();
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _shelfRefresh.dispose();
    unawaited(
      _library.then<void>(
        (WebLibrary library) => library.close(),
        onError: (Object error, StackTrace trace) {},
      ),
    );
    super.dispose();
  }
}

class _LocalBookRoute extends StatefulWidget {
  const _LocalBookRoute({
    required this.bookId,
    required this.library,
    required this.onReady,
    required this.onRetryLibrary,
  });

  final String bookId;
  final Future<WebLibrary> library;
  final ValueChanged<({WebLibrary library, WebReadingState state})> onReady;
  final VoidCallback onRetryLibrary;

  @override
  State<_LocalBookRoute> createState() => _LocalBookRouteState();
}

class _LocalBookRouteState extends State<_LocalBookRoute> {
  WebLibrary? _library;
  WebBook? _book;
  WebReadingState? _reading;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final Future<WebLibrary> source = widget.library;
    try {
      final WebLibrary library = await source;
      final WebBook? book = await library.load(widget.bookId);
      if (book == null) throw StateError('这本书不在当前浏览器的本地书库中。请先导入书籍或备份。');
      final WebReadingState reading = await library.state(widget.bookId);
      if (!mounted || source != widget.library) return;
      widget.onReady((library: library, state: reading));
      setState(() {
        _library = library;
        _book = book;
        _reading = reading;
      });
    } on Object {
      if (mounted && source == widget.library) {
        setState(() => _error = '暂时无法读取书库，请检查浏览器剩余空间后重试。');
      }
    }
  }

  @override
  void didUpdateWidget(_LocalBookRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      _library = null;
      _book = null;
      _reading = null;
      _error = null;
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_book != null && _reading != null && _library != null) {
      return WebReader(book: _book!, state: _reading!, library: _library!);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('打开本地书籍')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: widget.onRetryLibrary,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试打开书库'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回书架'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
