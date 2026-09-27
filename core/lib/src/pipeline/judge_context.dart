/// Per-book judge settings for reader requests that share an isolate.
///
/// Zone values keep simultaneous Ask and Marginalia requests on their own
/// book's budget and cache without changing process-wide model settings.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../env.dart';

const Symbol _directoryKey = #thusfarJudgeDirectory;
const Symbol _routeKey = #thusfarJudgeRoute;

String? scopedJudgeDirectory() => Zone.current[_directoryKey] as String?;

String? selectedJudgeDirectory() =>
    scopedJudgeDirectory() ?? environ['JUDGE_LOG_DIR'];

String selectedJudgeRoute() =>
    Zone.current[_routeKey] as String? ?? environ['JEV_ROUTE'] ?? 'free-only';

/// Freeze one worker attempt's route without changing another request's route.
Future<T> withJudgeRoute<T>(String route, Future<T> Function() action) =>
    runZoned(action, zoneValues: <Object, Object?>{_routeKey: route});

/// Explicit per-book choice. Old book metadata remains a model opt-in only.
String? bookJudgeRoute(Map<String, Object?> metadata) {
  if (metadata.containsKey('judge_fallback_route')) {
    return switch (metadata['judge_fallback_route']) {
      'model' => 'free-then-model',
      'jev' => 'free-then-paid',
      'model-direct' => 'model',
      'jev-direct' => 'paid',
      _ => null,
    };
  }
  return metadata['judge_model_fallback'] == true ? 'free-then-model' : null;
}

/// Run all judge calls for one reader request with its book-scoped allowance.
/// The per-book opt-in takes precedence over the global free-only setting;
/// other books and concurrent requests keep their own route.
Future<T> withBookJudgeContext<T>(
  Directory book,
  Future<T> Function() action,
) async {
  final File metadata = File('${book.path}/meta.json');
  String? bookRoute;
  if (metadata.existsSync()) {
    final Object? raw = jsonDecode(metadata.readAsStringSync());
    if (raw is! Map<String, Object?>) {
      throw const FormatException('书籍资料格式无效');
    }
    bookRoute = bookJudgeRoute(raw);
  }
  // Read the saved app-wide setting, not a parent request's Zone override.
  // A book without an opt-in must never inherit another book's paid route.
  final String route = bookRoute ?? environ['JEV_ROUTE'] ?? 'free-only';
  return runZoned(
    action,
    zoneValues: <Object, Object?>{
      _directoryKey: '${book.path}/work/judge',
      _routeKey: route,
    },
  );
}
