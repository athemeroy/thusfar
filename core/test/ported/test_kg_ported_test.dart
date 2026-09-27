// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
import 'package:test/test.dart';

import 'contract_invoker.dart';

const _paragraphs = <String>[
  '一个穿黑斗篷的人走进了客栈，大家都叫他黑衣人。',
  '掌柜的给黑衣人倒了一碗酒，黑衣人一句话也不说。',
  '夜深了，黑衣人摘下斗篷，原来他就是失踪多年的陈明。',
  '陈明对掌柜说：我回来了。掌柜的哭了。',
];

// This is the original synthetic extraction, including the model's deliberate
// mistake of crediting early events to the later-revealed 陈明.
final _extraction = <String, Object?>{
  'new_people': [
    {
      'ref': 'N1',
      'name': '黑衣人',
      'gender': '男',
      'importance': 3,
      'para': 1,
      'quote': '一个穿黑斗篷的人走进了客栈',
      'intro': '穿黑斗篷的神秘人',
    },
    {
      'ref': 'N2',
      'name': '掌柜',
      'gender': '男',
      'importance': 2,
      'para': 2,
      'quote': '掌柜的给黑衣人倒了一碗酒',
      'intro': '客栈掌柜',
    },
    {
      'ref': 'N3',
      'name': '陈明',
      'gender': '男',
      'importance': 3,
      'para': 3,
      'quote': '原来他就是失踪多年的陈明',
      'intro': '失踪多年的人',
    },
  ],
  'surfaces': {
    'N1': ['黑衣人'],
    'N2': ['*掌柜'],
    'N3': ['陈明'],
  },
  'aliases': [],
  'merges': [
    {
      'from': 'N1',
      'into': 'N3',
      'para': 3,
      'quote': '原来他就是失踪多年的陈明',
      'reason': '黑衣人摘下斗篷',
    },
  ],
  'events': [
    {
      'who': ['N3', 'N2'],
      'text': '陈明进客栈，掌柜给他倒酒',
      'para': 2,
      'quote': '掌柜的给黑衣人倒了一碗酒',
      'importance': 2,
    },
    {
      'who': ['N3'],
      'text': '陈明摘下斗篷露出真面目',
      'para': 3,
      'quote': '黑衣人摘下斗篷',
      'importance': 3,
    },
    {
      'who': ['N3', 'N2'],
      'text': '陈明对掌柜说他回来了',
      'para': 4,
      'quote': '陈明对掌柜说：我回来了',
      'importance': 2,
    },
  ],
  'attrs': [
    {'who': 'N2', 'key': '职业', 'value': '客栈掌柜', 'para': 1, 'quote': '走进了客栈'},
  ],
  'rels': [],
  'profiles': [
    {'who': 'N3', 'tagline': '失踪多年后归来的人', 'bio': '陈明失踪多年，今夜回到客栈。', 'para': 4},
  ],
};

/// Test-only setup adapter for the original KGTest.setUp sequence. The A4
/// owner must build paragraph blocks, call finish with [(0, '第一章', 0)], force
/// every chapter to body, take segments(book, [0])[0], plan on a fresh KG,
/// choose the first id for each ambiguous occurrence, then commit. It returns
/// {book, log, mentions, canonical_p1, fresh_plan}; fresh_plan is separately
/// computed by KG(book).plan(seg, extraction), as in the fifth Python test.
Map<String, Object?> _revealSetup() {
  final state =
      callPorted('tests.test_kg.reveal_setup', {
            'paragraphs': _paragraphs,
            'extraction': _extraction,
            'title': '测试书',
            'author': '作者',
          })
          as Map<String, Object?>;
  _reveal(_log(state)); // Python setUp requires a merge record.
  return state;
}

List<Map<String, Object?>> _log(Map<String, Object?> state) =>
    (state['log'] as List<Object?>).cast<Map<String, Object?>>();

Map<String, int> _intro(List<Map<String, Object?>> log) => {
  for (final row in log)
    if (row['t'] == 'person') row['id'] as String: row['p'] as int,
};

int _reveal(List<Map<String, Object?>> log) =>
    log.firstWhere((row) => row['t'] == 'merge')['p'] as int;

void main() {
  test(
    "tests.test_kg.KGTest.test_nothing_about_a_person_before_they_enter",
    () {
      final log = _log(_revealSetup());
      final intro = _intro(log);
      for (final row in log) {
        final id = row['id'];
        if ({'attr', 'profile', 'alias', 'name'}.contains(row['t']) &&
            id is String &&
            intro.containsKey(id)) {
          expect(
            row['p'] as int,
            greaterThanOrEqualTo(intro[id]!),
            reason: '$row',
          );
        }
      }
    },
    skip:
        "Dart implementation of pipeline.extract, pipeline.kg, pipeline.parse, server.temporal is pending (A2, A4, A6); required to check 'nothing about a person before they enter'.",
  );
  test(
    "tests.test_kg.KGTest.test_early_events_belong_to_the_identity_the_reader_knows",
    () {
      final log = _log(_revealSetup());
      final reveal = _reveal(log);
      final early =
          log
              .where((row) => row['t'] == 'event' && (row['p'] as int) < reveal)
              .toList();
      expect(early, isNotEmpty);
      for (final row in early) {
        final who = row['who'] as List<Object?>;
        expect(who, isNot(contains('P3')), reason: '$row');
        expect(who, contains('P1'), reason: '$row');
      }
    },
    skip:
        "Dart implementation of pipeline.extract, pipeline.kg, pipeline.parse, server.temporal is pending (A2, A4, A6); required to check 'early events belong to the identity the reader knows'.",
  );
  test(
    "tests.test_kg.KGTest.test_revealed_name_not_used_before_the_reveal",
    () {
      final state = _revealSetup();
      final book = state['book'] as Map<String, Object?>;
      final blocks =
          (book['blocks'] as List<Object?>).cast<Map<String, Object?>>();
      final firstNamedOffset = blocks[2]['o'] as int;
      for (final row in _log(state)) {
        final text = [
          'text',
          'tagline',
          'bio',
          'intro',
          'value',
        ].map((key) => row[key]?.toString() ?? '').join(' ');
        if (text.contains('陈明')) {
          expect(
            row['p'] as int,
            greaterThanOrEqualTo(firstNamedOffset),
            reason: '$row',
          );
        }
      }
    },
    skip:
        "Dart implementation of pipeline.extract, pipeline.kg, pipeline.parse, server.temporal is pending (A2, A4, A6); required to check 'revealed name not used before the reveal'.",
  );
  test(
    "tests.test_kg.KGTest.test_merge_links_the_two_records",
    () {
      final state = _revealSetup();
      final merge = _log(state).firstWhere((row) => row['t'] == 'merge');
      expect([merge['from'], merge['into']], ['P1', 'P3']);
      expect(state['canonical_p1'], 'P3');
    },
    skip:
        "Dart implementation of pipeline.extract, pipeline.kg, pipeline.parse, server.temporal is pending (A2, A4, A6); required to check 'merge links the two records'.",
  );
  test(
    "tests.test_kg.KGTest.test_generic_title_needs_a_decision",
    () {
      final plan = _revealSetup()['fresh_plan'] as Map<String, Object?>;
      final occurrences =
          (plan['occs'] as List<Object?>).cast<Map<String, Object?>>();
      final ambiguous = {
        for (final row in occurrences)
          if (row['ambiguous'] == true) row['surface'] as String,
      };
      expect(ambiguous, contains('掌柜'));
      expect(ambiguous, isNot(contains('陈明')));
    },
    skip:
        "Dart implementation of pipeline.kg.KG.__init__ is pending (A2, A4, A6); required to check 'generic title needs a decision'.",
  );
  test(
    "tests.test_kg.KGTest.test_mentions_are_positioned_on_the_text",
    () {
      final state = _revealSetup();
      final book = state['book'] as Map<String, Object?>;
      final blocks =
          (book['blocks'] as List<Object?>).cast<Map<String, Object?>>();
      final full = blocks.map((block) => block['t'] as String).join('\n');
      final mentions = state['mentions'] as List<Object?>;
      for (final mention in mentions) {
        final row = mention as List<Object?>;
        final start = row[0] as int;
        final end = row[1] as int;
        // The source paragraphs are all BMP, so Dart UTF-16 slicing matches
        // the Python string slicing in this particular original fixture.
        expect(['黑衣人', '陈明', '掌柜'], contains(full.substring(start, end)));
      }
    },
    skip:
        "Dart implementation of pipeline.extract, pipeline.kg, pipeline.parse, server.temporal is pending (A2, A4, A6); required to check 'mentions are positioned on the text'.",
  );
  test(
    "tests.test_kg.TextTest.test_generic_reveal_keeps_old_label_only_before_the_reveal",
    () {
      expect(callPorted('pipeline.kg.generic_word', {'f': '少女'}), isTrue);
      final log = <Map<String, Object?>>[
        {'t': 'person', 'p': 10, 'id': 'P1', 'name': '少女'},
        {'t': 'person', 'p': 30, 'id': 'P2', 'name': '丛雨'},
        {'t': 'merge', 'p': 35, 'from': 'P2', 'into': 'P1'},
      ];
      Map<String, Object?> personAt(int pos) {
        final world =
            callPorted('server.temporal.fold', {'log': log, 'pos': pos})
                as Map<String, Object?>;
        final people = world['people'] as Map<String, Object?>;
        return people['P1'] as Map<String, Object?>;
      }

      expect(personAt(34)['name'], '少女');
      final after = personAt(35);
      expect(after['name'], '丛雨');
      expect(after['aliases'] as Iterable<Object?>, isNot(contains('少女')));

      // Test-only adapter reproduces KG(make_book(...)), assigns the two
      // original mutable people records (alias lists below become sets), calls
      // merge('P2', 'P1', 35, 30, '原文点名'), and returns kg.people.
      final people =
          callPorted('tests.test_kg.generic_reveal_merge_setup', {
                'paragraphs': ['少女自称丛雨。'],
                'title': '测试书',
                'author': '作者',
                'people': {
                  'P1': {
                    'name': '少女',
                    'aliases': ['少女'],
                    'mentions': 1,
                  },
                  'P2': {
                    'name': '丛雨',
                    'aliases': ['丛雨'],
                    'mentions': 1,
                  },
                },
                'merge': {
                  'a': 'P2',
                  'b': 'P1',
                  'p': 35,
                  's': 30,
                  'reason': '原文点名',
                },
              })
              as Map<String, Object?>;
      expect((people['P1'] as Map<String, Object?>)['name'], '丛雨');
    },
    skip:
        "Dart implementation of pipeline.kg.KG.__init__, pipeline.kg.generic_word, server.temporal.fold is pending (A2, A4, A6); required to check 'generic reveal keeps old label only before the reveal'.",
  );
  test(
    "tests.test_kg.TextTest.test_zh_punctuation",
    () {
      expect(
        callPorted('pipeline.kg.zh', {'text': '他说"好",然后(笑了)'}),
        '他说“好”，然后（笑了）',
      );
      expect(
        callPorted('pipeline.kg.zh', {'text': 'Hello, world'}),
        'Hello, world',
      );
    },
    skip:
        "Dart implementation of pipeline.kg.zh is pending (A2, A4, A6); required to check 'zh punctuation'.",
  );
  test(
    "tests.test_kg.TextTest.test_alias_filter",
    () {
      for (final bad in ['太太', '查理夫妇', '卢欧老爹的女儿', '未婚女婿', '他们']) {
        expect(
          callPorted('pipeline.kg.good_alias', {'a': bad}),
          isFalse,
          reason: bad,
        );
      }
      for (final ok in ['老Q', '小D', '爱玛', '包法利先生']) {
        expect(
          callPorted('pipeline.kg.good_alias', {'a': ok}),
          isTrue,
          reason: ok,
        );
      }
    },
    skip:
        "Dart implementation of pipeline.kg.good_alias is pending (A2, A4, A6); required to check 'alias filter'.",
  );
}
