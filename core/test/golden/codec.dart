import 'dart:convert';
import 'dart:typed_data';

import 'package:thusfar_core/src/errors.dart';
import 'package:thusfar_core/src/py/py_json.dart';

/// Decodes the recorder's tagged JSON (`$tuple`, `$set`, `$bytes`, `$path`,
/// `$map`, `$float`) into the Dart values the ported functions take.
Object? decodeInput(Object? value) {
  if (value is List<Object?>)
    return <Object?>[for (final Object? v in value) decodeInput(v)];
  if (value is! Map<String, Object?>) return value;
  if (value.length == 1) {
    final MapEntry<String, Object?> only = value.entries.first;
    switch (only.key) {
      case r'$tuple':
        return decodeInput(only.value);
      case r'$set':
        return <Object?>{
          for (final Object? v in only.value! as List<Object?>) decodeInput(v),
        };
      case r'$bytes':
        return Uint8List.fromList(base64.decode(only.value! as String));
      case r'$path':
        return only.value;
      case r'$float':
        return switch (only.value) {
          'nan' => double.nan,
          'inf' => double.infinity,
          _ => double.negativeInfinity,
        };
      case r'$map':
        return <Object?, Object?>{
          for (final Object? pair in only.value! as List<Object?>)
            decodeInput((pair! as List<Object?>)[0]): decodeInput(
              (pair as List<Object?>)[1],
            ),
        };
    }
  }
  return <String, Object?>{
    for (final MapEntry<String, Object?> e in value.entries)
      e.key: decodeInput(e.value),
  };
}

String _canonical(Object? value) =>
    PyJson.encode(value, ensureAscii: false, compact: true, allowNan: false);

/// Encodes a Dart result the way the recorder encoded the Python result.
Object? encodeOutput(Object? value) {
  if (value == null || value is bool || value is int || value is String)
    return value;
  if (value is double) {
    if (value.isNaN) return <String, Object?>{r'$float': 'nan'};
    if (value.isInfinite)
      return <String, Object?>{r'$float': value > 0 ? 'inf' : '-inf'};
    return value;
  }
  if (value is Uint8List)
    return <String, Object?>{r'$bytes': base64.encode(value)};
  if (value is PyException) {
    return <String, Object?>{
      r'$error': <String, Object?>{
        'type': value.pyType,
        'message': value.message,
      },
    };
  }
  if (value is Record)
    return <String, Object?>{
      r'$tuple': _recordFields(value).map(encodeOutput).toList(),
    };
  if (value is Set<Object?>) {
    final List<Object?> items =
        value.map(encodeOutput).toList()..sort(
          (Object? a, Object? b) => _canonical(a).compareTo(_canonical(b)),
        );
    return <String, Object?>{r'$set': items};
  }
  if (value is List<Object?>) return value.map(encodeOutput).toList();
  if (value is Map<Object?, Object?>) {
    if (value.keys.every((Object? k) => k is String)) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries)
          e.key! as String: encodeOutput(e.value),
      };
    }
    return <String, Object?>{
      r'$map': <Object?>[
        for (final MapEntry<Object?, Object?> e in value.entries)
          <Object?>[encodeOutput(e.key), encodeOutput(e.value)],
      ],
    };
  }
  throw ArgumentError('cannot encode ${value.runtimeType}');
}

/// A Python tuple returned by a port: Dart records of arity 2–4.
List<Object?> _recordFields(Record r) => switch (r) {
  (final Object? a, final Object? b) => <Object?>[a, b],
  (final Object? a, final Object? b, final Object? c) => <Object?>[a, b, c],
  (final Object? a, final Object? b, final Object? c, final Object? d) =>
    <Object?>[a, b, c, d],
  _ => throw ArgumentError('unsupported record arity $r'),
};

/// Runs [body] and encodes either its value or its Python-typed exception.
Object? guard(Object? Function() body) {
  try {
    return encodeOutput(body());
  } on PyException catch (error) {
    return encodeOutput(error);
  }
}
