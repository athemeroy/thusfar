import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:thusfar_core/src/pipeline/kg.dart';
import 'package:thusfar_core/src/py/py_int.dart';
import '../golden/codec.dart';

typedef Json = Map<String, Object?>;
Json _read(String path) =>
    decodeInput(jsonDecode(File(path).readAsStringSync()))! as Json;
List<Json> _goldens(String method) =>
    File('../oracle/goldens/pipeline/kg/$method.jsonl')
        .readAsLinesSync()
        .where((x) => x.isNotEmpty)
        .map((line) => jsonDecode(line)! as Json)
        .toList();
Json _fields(Json i) => (i['self']! as Json)['fields']! as Json;
Map<String, Json> _people(Object? value) => {
  for (final MapEntry<String, Object?> e in ((value as Json?) ?? {}).entries)
    e.key: {
      ...(e.value! as Json),
      if ((e.value! as Json)['aliases'] != null)
        'aliases':
            ((e.value! as Json)['aliases']! as Iterable<Object?>)
                .cast<String>()
                .toSet(),
      if ((e.value! as Json)['weak'] != null)
        'weak':
            ((e.value! as Json)['weak']! as Iterable<Object?>)
                .cast<String>()
                .toSet(),
    },
};
KG _restore(Json fields, [Json? book]) {
  final KG kg = KG(
    book ?? fields['book'] as Json? ?? {'lang': 'zh', 'blocks': <Object?>[]},
  );
  kg.people = _people(fields['people']);
  kg.rels = {
    for (final MapEntry<String, Object?> e
        in ((fields['rels'] as Json?) ?? {}).entries)
      e.key: e.value! as Json,
  };
  kg.n = fields['n'] as int? ?? 0;
  kg.seg = fields['seg'] as int? ?? 0;
  kg.recent = (fields['recent'] as List<Object?>?)?.cast<String>() ?? [];
  kg.saga = fields['saga'] as String? ?? '';
  kg.log = (fields['log'] as List<Object?>?)?.cast<Json>() ?? [];
  kg.mentions =
      (fields['mentions'] as List<Object?>?)?.cast<List<Object?>>() ?? [];
  kg.warnings = (fields['warnings'] as List<Object?>?)?.cast<String>() ?? [];
  return kg;
}

Json _state(KG kg) => {
  'people': kg.people,
  'rels': kg.rels,
  'log': kg.log,
  'mentions': kg.mentions,
  'recent': kg.recent,
  'saga': kg.saga,
  'n': kg.n,
  'seg': kg.seg,
  'warnings': kg.warnings,
};
Object? _tuple5(
  (
    List<Json>,
    List<List<Object?>>,
    List<Json>,
    List<List<Object?>>,
    Map<String, int>,
  )
  r,
) => {
  r'$tuple': [r.$1, r.$2, r.$3, r.$4, r.$5].map(encodeOutput).toList(),
};

void main() {
  test(
    'Python decimal strings preserve paragraph selection and Unicode version',
    () {
      for (final String text in ['1', '+１', '١', '\u00851\u0085', '𝟙']) {
        expect(tryPythonDecimal(text), BigInt.one, reason: text);
      }
      expect(tryPythonDecimal('1_0'), BigInt.from(10));
      expect(tryPythonDecimal('-١_٢'), BigInt.from(-12));
      expect(
        tryPythonDecimal('9223372036854775808123'),
        BigInt.parse('9223372036854775808123'),
      );
      for (final String text in [
        '0x1',
        '²',
        '1__0',
        '_1',
        '1_',
        '\x1c1',
        '1\x1d',
        '\x1e1',
        '1\x1f',
        '\u{11f51}',
        '\u{1e4f1}',
      ]) {
        expect(tryPythonDecimal(text), isNull, reason: text);
      }
      final List<Json> blocks = [
        for (int i = 0; i < 10; i++) {'t': '甲乙', 'o': i * 3},
      ];
      final Anchor anchor = Anchor.fromBlocks(blocks, {'o1': 29});
      for (final String text in ['１', '١', '+１', '𝟙']) {
        expect(anchor.pos(text, null), (0, 2), reason: text);
      }
      expect(anchor.pos('1_0', null), (27, 29));
      expect(anchor.pos('0x1', null), (29, 29));
    },
  );
  final Map<String, Object? Function(Json)> functions = {
    'is_latin': (i) => isLatin(i['s'] as String?),
    'generic_word': (i) => genericWord(i['f'] as String?),
    'good_alias': (i) => goodAlias(i['a'] as String?),
    'zh': (i) => zh(i['text']),
    '_norm': (i) => normalizeQuote(i['s']! as String),
    'Anchor/_g':
        (i) => Anchor.fromBlocks(
          [],
        ).globalPosition(i['b']! as Json, i['i']! as int),
    'Anchor/block':
        (i) => Anchor.fromBlocks(
          (_fields(i)['blocks']! as List<Object?>).cast<Json>(),
        ).block(i['para']),
    'Anchor/find':
        (i) => Anchor.fromBlocks(
          (_fields(i)['blocks']! as List<Object?>).cast<Json>(),
        ).find(i['quote'] as String?, i['para']),
    'Anchor/first':
        (i) => Anchor.fromBlocks(
          (_fields(i)['blocks']! as List<Object?>).cast<Json>(),
        ).first(i['surface']! as String, i['after'] as int? ?? -1),
    'Anchor/para_end':
        (i) => Anchor.fromBlocks(
          (_fields(i)['blocks']! as List<Object?>).cast<Json>(),
        ).paraEnd(i['para']),
    'KG/canon': (i) => _restore(_fields(i)).canon(i['pid'] as String?),
    'KG/describe': (i) => _restore(_fields(i)).describe(i['pid']! as String),
    'KG/lookup':
        (i) => _restore(_fields(i)).lookup(i['x'], i['refmap']! as Json),
    'KG/plan':
        (i) => _restore(_fields(i)).plan(i['seg']! as Json, i['data']! as Json),
    'KG/prompt_state': (i) => _restore(_fields(i)).promptState(),
  };
  for (final MapEntry<String, Object? Function(Json)> e in functions.entries) {
    test('Python golden ${e.key}', () {
      final List<Json> rows = _goldens(e.key);
      for (int index = 0; index < rows.length; index++) {
        final Json input = decodeInput(rows[index]['input'])! as Json;
        expect(
          encodeOutput(e.value(input)),
          rows[index]['output'],
          reason: '${e.key} row $index',
        );
      }
    });
  }
  test('Python golden quarantine_identities', () {
    final List<Json> rows = _goldens('quarantine_identities');
    for (int index = 0; index < rows.length; index++) {
      final Json input = decodeInput(rows[index]['input'])! as Json;
      expect(
        _tuple5(
          quarantineIdentities(
            (input['records']! as List<Object?>).cast<Json>(),
            (input['mentions']! as List<Object?>).cast<List<Object?>>(),
            (input['seeds']! as Json).cast<String, int>(),
          ),
        ),
        rows[index]['output'],
        reason: 'quarantine row $index',
      );
    }
  });
  final Json fixture = _read('test/kg/fixtures/kg_differential.json');
  void compareCommit(Json input) {
    final KG kg = _restore(
      input['initial'] as Json? ?? {},
      input['book']! as Json,
    );
    final Json segment = input['seg']! as Json;
    final Json data = input['data']! as Json;
    final Json planned = kg.plan(segment, data);
    final Json decisions = {
      for (final Object? raw in planned['occs']! as List<Object?>)
        if ((raw! as Json)['ambiguous'] == true)
          (raw as Json)['key']! as String: (raw['ids']! as List<Object?>).first,
    };
    final List<Json> committed = kg.commit(
      segment,
      data,
      planned,
      decisions,
      input['guard'] as Json?,
    );
    final Json actual = {
      'plan': planned,
      'committed': committed,
      'state': _state(kg),
      'prompt_state': kg.promptState(),
      'data_after': data,
    };
    expect(encodeOutput(actual), encodeOutput(input['expected']));
  }

  for (final Json c in (fixture['synthetic']! as List<Object?>).cast<Json>()) {
    test('Python differential commit ${c['name']}', () => compareCommit(c));
  }
  final List<Json> captured = _goldens('KG/plan');
  for (final Json c in (fixture['captured']! as List<Object?>).cast<Json>()) {
    test('Python differential captured commit ${c['source_row']}', () {
      final Json i =
          decodeInput(captured[c['source_row']! as int]['input'])! as Json;
      final Json fields = _fields(i);
      compareCommit({
        'book': fields['book'],
        'initial': fields,
        'seg': c['seg'],
        'data': i['data'],
        'expected': c['expected'],
      });
    });
  }
  test(
    'Anchor Unicode, quote normalization, fallbacks and Latin boundaries',
    () {
      final Json f = fixture['anchor']! as Json;
      final Anchor anchor = Anchor(f['book']! as Json, f['seg']! as Json);
      for (final Json c in (f['calls']! as List<Object?>).cast<Json>()) {
        final List<Object?> args = c['args']! as List<Object?>;
        final Object? actual = switch (c['method']) {
          'find' => anchor.find(args[0] as String?, args[1]),
          'pos' => anchor.pos(args[0], args[1] as String?),
          'para_end' => anchor.paraEnd(args[0]),
          'block' => anchor.block(args[0]),
          'first' => anchor.first(args[0]! as String, args[1]! as int),
          _ => throw StateError('unexpected anchor case'),
        };
        final Object? expected =
            c['expected'] is List<Object?>
                ? {r'$tuple': encodeOutput(c['expected'])}
                : encodeOutput(c['expected']);
        expect(encodeOutput(actual), expected, reason: '${c['method']} $args');
      }
    },
  );
  test(
    'merge aliases, relation rewrite and recap append preserve graph state',
    () {
      final KG kg = KG({'lang': 'zh', 'blocks': <Object?>[]});
      kg.people = {
        'P1': {
          'name': '少女',
          'aliases': <String>{'少女'},
          'mentions': 1,
        },
        'P2': {
          'name': '丛雨',
          'aliases': <String>{'丛雨'},
          'mentions': 2,
          'imp': 3,
          'weak': <String>{'姑娘'},
        },
        'P3': {
          'name': 'Ann',
          'aliases': <String>{'Ann'},
          'mentions': 0,
        },
      };
      kg.rels = {
        'P1|P2': {'a': 'P1', 'b': 'P2'},
        'P2|P3': {'a': 'P2', 'b': 'P3', 'desc': '朋友'},
      };
      final Json record = kg.merge('P2', 'P1', 35, 30, '原文点名', 'manual');
      expect(kg.log, isEmpty);
      expect(record['kind'], 'manual');
      expect(kg.canon('P2'), 'P1');
      expect(kg.people['P1']!['name'], '丛雨');
      expect(kg.people['P1']!['aliases'], {'少女', '丛雨'});
      expect(kg.people['P1']!['weak'], {'姑娘'});
      expect(kg.people['P1']!['mentions'], 3);
      expect(kg.people['P1']!['imp'], 3);
      expect(kg.rels, {
        'P1|P3': {'a': 'P1', 'b': 'P3', 'desc': '朋友'},
      });
      kg.addRecap(2, 40, '她说"是",点头', '少女:丛雨');
      kg.addRecap(3, 50, '', '');
      expect(kg.log, [
        {'t': 'recap', 'p': 40, 'chapter': 2, 'text': '她说“是”，点头'},
        {'t': 'saga', 'p': 40, 'text': '少女：丛雨'},
      ]);
      expect(kg.saga, '少女：丛雨');
    },
  );
}
