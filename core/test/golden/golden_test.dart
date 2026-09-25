import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'golden_registry.dart';

void main() {
  final Map<String, List<Map<String, Object?>>> specialByFunction = {};
  final List<File> specialFiles =
      Directory('../oracle/goldens/special')
          .listSync()
          .whereType<File>()
          .where((File file) => file.path.endsWith('.jsonl'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in specialFiles) {
    for (final String line in file.readAsLinesSync()) {
      final Map<String, Object?> sample =
          jsonDecode(line) as Map<String, Object?>;
      final String function = sample['function'] as String;
      specialByFunction.putIfAbsent(function, () => []).add(sample);
    }
  }
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

  test('special goldens are indexed to inventoried functions', () {
    expect(specialFiles, isNotEmpty);
    expect(specialByFunction.keys, everyElement(isIn(expected)));
    for (final MapEntry<String, List<Map<String, Object?>>> entry
        in specialByFunction.entries) {
      final Set<String> cases = {};
      for (final Map<String, Object?> sample in entry.value) {
        expect(sample['schema'], 1);
        expect(sample['function'], entry.key);
        final String name = sample['case'] as String;
        expect(cases.add(name), isTrue, reason: '${entry.key} $name');
        if (sample.containsKey('before')) {
          expect(sample['before'], isA<Map<String, Object?>>());
          expect(sample['after'], isA<Map<String, Object?>>());
          expect(sample.containsKey('return'), isTrue);
        } else {
          expect(sample['input'], isA<Map<String, Object?>>());
          expect(sample.containsKey('output'), isTrue);
        }
      }
    }
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
        final SpecialGoldenInvoker? invokeSpecial = specialGoldenRegistry[id];
        final List<String> parts = id.split('.');
        final String path =
            '../oracle/goldens/${parts.sublist(0, parts.length - 1).join('/')}/${parts.last}.jsonl';
        final File ordinary = File(path);
        final List<Map<String, Object?>> special =
            specialByFunction[id] ?? <Map<String, Object?>>[];
        test('$stage $id has an adapter and recorded cases', () {
          expect(ordinary.existsSync() || special.isNotEmpty, isTrue);
          if (ordinary.existsSync()) {
            expect(invoke, isNotNull);
            expect(ordinary.readAsLinesSync(), isNotEmpty);
          }
          if (special.isNotEmpty) {
            expect(invokeSpecial, isNotNull);
          }
        });
        if (invoke != null && ordinary.existsSync()) {
          int index = 0;
          for (final String line in ordinary.readAsLinesSync()) {
            final Map<String, Object?> sample =
                jsonDecode(line) as Map<String, Object?>;
            final Map<String, Object?> input =
                sample['input']! as Map<String, Object?>;
            test('$stage $id sample ${index++}', () {
              expect(invoke(input), sample['output']);
            });
          }
        }
        if (invokeSpecial != null) {
          for (final Map<String, Object?> sample in special) {
            final bool stateful = sample.containsKey('before');
            final Map<String, Object?> input =
                (stateful ? sample['before'] : sample['input'])!
                    as Map<String, Object?>;
            final Object? expectedOutput =
                stateful
                    ? <String, Object?>{
                      'after': sample['after'],
                      'return': sample['return'],
                      if (sample.containsKey('aliases'))
                        'aliases': sample['aliases'],
                    }
                    : sample['output'];
            test('$stage $id special ${sample['case']}', () {
              expect(invokeSpecial(input), expectedOutput);
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
