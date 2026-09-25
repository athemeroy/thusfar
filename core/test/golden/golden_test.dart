import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'golden_registry.dart';

void main() {
  final YamlMap manifest =
      loadYaml(File('../docs/port/MANIFEST.yaml').readAsStringSync())
          as YamlMap;
  final Map<String, Object?> inventory =
      jsonDecode(File('../docs/port/inventory.json').readAsStringSync())
          as Map<String, Object?>;
  final YamlList entries = manifest['functions'] as YamlList;
  final List<Object?> rawInventory = inventory['functions']! as List<Object?>;
  final List<String> expected =
      rawInventory
          .map((Object? row) => (row! as Map<String, Object?>)['id']! as String)
          .toList();
  final List<String> actual =
      entries.map((Object? row) => (row! as YamlMap)['id'] as String).toList();

  test('all 378 Python functions have one Dart port status', () {
    expect(manifest['schema'], 1);
    expect(manifest['oracle'], 'python-1.7.5');
    expect(actual, expected);
    expect(actual.toSet().length, 378);
  });

  for (final Object? raw in entries) {
    final YamlMap entry = raw! as YamlMap;
    final String id = entry['id'] as String;
    final String status = entry['status'] as String;
    final String stage = entry['stage'] as String;
    final String? reason = entry['reason'] as String?;
    switch (status) {
      case 'pending_port':
      case 'not_ported':
        test('$stage $id', () => fail('Unported function $id'), skip: reason);
      case 'golden_passed':
        final GoldenInvoker? invoke = goldenRegistry[id];
        final List<String> parts = id.split('.');
        final String path =
            '../oracle/goldens/${parts.sublist(0, parts.length - 1).join('/')}/${parts.last}.jsonl';
        test('$stage $id has an adapter and recorded cases', () {
          expect(invoke, isNotNull);
          expect(File(path).existsSync(), isTrue);
          expect(File(path).readAsLinesSync(), isNotEmpty);
        });
        if (invoke != null && File(path).existsSync()) {
          int index = 0;
          for (final String line in File(path).readAsLinesSync()) {
            final Map<String, Object?> sample =
                jsonDecode(line) as Map<String, Object?>;
            final Map<String, Object?> input =
                sample['input']! as Map<String, Object?>;
            test('$stage $id sample ${index++}', () {
              expect(invoke(input), sample['output']);
            });
          }
        }
      default:
        test('$stage $id has valid status', () {
          fail('Invalid status: $status');
        });
    }
  }
}
