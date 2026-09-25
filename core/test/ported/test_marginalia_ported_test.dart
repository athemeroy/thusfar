// Contracts translated from tests/test_marginalia.py. The synthetic scripted
// service adapter remains skipped until the Dart marginalia owner exists.
import 'dart:convert';

import 'package:test/test.dart';

import 'contract_invoker.dart';

int _u16(String text) => callPorted('pipeline.parse.u16', {'s': text}) as int;

typedef Json = Map<String, Object?>;

Json obj(Object? value) => value as Json;
List<Object?> array(Object? value) => value as List<Object?>;
Json response(Json run, int index) => obj(array(run['responses'])[index]);
Json content(Json run, int index) => obj(response(run, index)['json']);
List<Json> calls(Json run, String kind) =>
    array(obj(run['calls'])[kind]).cast<Json>();

Json storyFixture() {
  const text = '她已经听懂了暗示。那封信被她折成很小的一方。后来真相终于出现。';
  const quote = '那封信被她折成很小的一方。';
  final start = _u16('她已经听懂了暗示。');
  final end = start + _u16(quote);
  final length = _u16(text) + 1;
  return {
    'start': start,
    'end': end,
    'quote': quote,
    'bookLength': length,
    'files': {
      'book.json': {
        'title': '故事',
        'author': '测试',
        'len': length,
        'lang': 'zh-CN',
        'notes': <String, Object?>{},
        'blocks': [
          {'k': 'p', 't': text, 'o': 0, 'fn': <Object?>[]},
        ],
        'chapters': [
          {
            'title': '第一章',
            'b0': 0,
            'b1': 1,
            'o0': 0,
            'o1': _u16(text),
            'kind': 'body',
          },
        ],
      },
      'meta.json': {'auto': false},
      'status.json': {'state': 'done', 'frontier': length},
      'kg.json': {
        'log': [
          {'t': 'saga', 'p': 2, 'text': '她收到了一封来历不明的信。'},
          {'t': 'event', 'p': start, 'who': <Object?>[], 'text': '她听懂了暗示。'},
          {
            't': 'event',
            'p': end + 1,
            'who': <Object?>[],
            'text': '未来事件绝不能出现。',
          },
        ],
      },
    },
  };
}

/// Runs real Dart marginalia HTTP code with only synthetic files. Operations
/// are a POST `request`, `parallel` POSTs with a generation barrier, or a
/// `graphInsert` mutation between calls. `stubs` supplies deterministic
/// jev/chat/guard results; unlisted model calls are forbidden. Output contains
/// ordered `responses` ({status,json}), `calls` (chat/guard/jev/generateMany),
/// `cacheRows`, and recorded overlap counts for concurrency checks. Synthetic
/// files start at revision 1; graphInsert increments it. Timestamps use the
/// fixed clock below.
Json marginaliaRun(Json fixture, List<Json> operations, Json stubs) =>
    callPorted('server.marginalia#scripted_http', {
          'bookId': 'story',
          'files': fixture['files'],
          'operations': operations,
          'stubs': stubs,
          'clockEpochSeconds': 1700000000,
          'initialFileRevision': 1,
          'forbidUnscriptedModelCalls': true,
        })
        as Json;

Json request(Json payload, {bool forbidGenerate = false}) => {
  'request': {
    'method': 'POST',
    'path': '/api/books/story/marginalia',
    'body': payload,
    'forbidGenerate': forbidGenerate,
  },
};

void main() {
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_distinct_prefetch_pages_run_concurrently_and_keep_both_cache_rows",
    () {
      final fixture = storyFixture();
      final length = fixture['bookLength']! as int;
      final first = {
        'mode': 'auto',
        'purpose': 'prefetch',
        'pos': 18,
        'page_start': 0,
        'page_end': 18,
        'persona': 'auto',
      };
      final second = {
        'mode': 'auto',
        'purpose': 'prefetch',
        'pos': length - 1,
        'page_start': 18,
        'page_end': length - 1,
        'persona': 'auto',
      };
      final run = marginaliaRun(
        fixture,
        [
          {
            'parallel': [request(first)['request'], request(second)['request']],
            'barrier': {'at': '_generate_many', 'parties': 2},
          },
          request({...first, 'purpose': 'visible'}, forbidGenerate: true),
        ],
        {
          'generateMany': [
            {
              'persona': 'empathy',
              'comment': '这封信被折起来，话却像还在纸上。',
              'guard': {'verdict': 'ok', 'p': 0.9},
            },
          ],
        },
      );
      expect(
        [response(run, 0)['status'], response(run, 1)['status']],
        [200, 200],
      );
      expect(calls(run, 'generateMany'), hasLength(2));
      expect(run['maximumConcurrentGenerateMany'], greaterThanOrEqualTo(2));
      expect(array(run['cacheRows']), hasLength(2));
      expect(
        [response(run, 2)['status'], content(run, 2)['cached']],
        [200, true],
      );
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_manual_comment_uses_only_text_through_anchor_and_reuses_cache",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final payload = {
        'mode': 'manual',
        'pos': end,
        'start': start,
        'end': end,
        'persona': 'cold',
      };
      final run = marginaliaRun(
        fixture,
        [
          request(payload),
          request(payload),
          {
            'graphInsert': {
              'beforeLogIndex': 2,
              'record': {
                't': 'event',
                'p': start + 1,
                'who': <Object?>[],
                'text': '她把信藏进了袖口。',
              },
            },
          },
          request(payload),
        ],
        {
          'chat': {'reply': '折得越小，藏不住的心事越大。'},
          'guard': {
            'comment': {'verdict': 'ok', 'p': 0.93},
          },
        },
      );
      expect(response(run, 0)['status'], 200);
      final first = content(run, 0);
      expect(
        [first['quote'], first['persona'], first['cached']],
        [fixture['quote'], 'cold', false],
      );
      expect(first['created'], 1700000000);
      final chats = calls(run, 'chat');
      expect(chats, hasLength(2));
      final firstPrompt =
          obj(array(chats.first['messages']).last)['content']! as String;
      expect(firstPrompt, contains('她收到了一封来历不明的信'));
      expect(firstPrompt, contains(fixture['quote']));
      expect(firstPrompt, isNot(contains('后来真相')));
      expect(firstPrompt, isNot(contains('未来事件绝不能出现')));
      expect(obj(calls(run, 'guard').first)['text'], isNot(contains('后来真相')));
      expect(
        [response(run, 1)['status'], content(run, 1)['cached']],
        [200, true],
      );
      expect(
        [response(run, 2)['status'], content(run, 2)['cached']],
        [200, false],
      );
      final lastPrompt =
          obj(array(chats.last['messages']).last)['content']! as String;
      expect(lastPrompt, contains('她把信藏进了袖口'));
      expect(array(run['cacheRows']), hasLength(2));
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_auto_reaction_uses_only_visible_page_and_reuses_cache",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final payload = {
        'mode': 'auto',
        'pos': end,
        'page_start': start,
        'page_end': end,
        'persona': 'auto',
      };
      final run = marginaliaRun(
        fixture,
        [request(payload), request(payload)],
        {
          'chat': {'reply': '她把信折得这么小，分明是不想让人看见。'},
          'guard': {
            for (final persona in ['empathy', 'detective', 'wit'])
              persona: {'verdict': 'ok', 'p': 0.88},
          },
        },
      );
      expect(response(run, 0)['status'], 200);
      expect(
        [response(run, 1)['status'], content(run, 1)['cached']],
        [200, true],
      );
      final chats = calls(run, 'chat');
      expect(chats, hasLength(3));
      final first = content(run, 0);
      expect(
        [first['start'], first['end'], first['persona'], first['kind']],
        [start, end, 'empathy', 'reader'],
      );
      expect(chats.first['model'], run['autoModel']);
      final prompt =
          obj(array(chats.first['messages']).last)['content']! as String;
      expect(prompt, contains('她收到了一封来历不明的信'));
      expect(prompt, contains(fixture['quote']));
      expect(prompt, isNot(contains('未来事件绝不能出现')));
      expect(prompt, isNot(contains('后来真相')));
      expect(calls(run, 'guard').last['text'], isNot(contains('未来事件绝不能出现')));
      expect(array(first['items']), hasLength(1));
      expect((first['end']! as int), lessThanOrEqualTo(end));
      expect(
        (first['position']! as int),
        lessThanOrEqualTo(fixture['bookLength']! as int),
      );
      expect(first['knowledge_cutoff'], end);
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_page_cues_call_jev_once_but_never_generate_prose_until_tapped",
    () {
      final fixture = storyFixture();
      final end = fixture['end']! as int;
      final payload = {
        'mode': 'cues',
        'pos': end,
        'page_start': 0,
        'page_end': end,
        'persona': 'auto',
      };
      final run = marginaliaRun(
        fixture,
        [request(payload), request(payload)],
        {
          'jev': {
            's1': {
              'choice': 'ordinary',
              'probabilities': {'ordinary': 0.92},
            },
            's2': {
              'choice': 'clue',
              'probabilities': {'ordinary': 0.05, 'clue': 0.90},
            },
          },
          'chat': {'forbidden': true},
        },
      );
      expect(
        [
          response(run, 0)['status'],
          response(run, 1)['status'],
          content(run, 1)['cached'],
        ],
        [200, 200, true],
      );
      expect(calls(run, 'jev'), hasLength(1));
      expect(calls(run, 'chat'), isEmpty);
      final items = array(content(run, 0)['items']);
      expect(items, hasLength(1));
      expect(
        [obj(items.first)['quote'], obj(items.first)['persona']],
        [fixture['quote'], 'detective'],
      );
      expect(obj(items.first).containsKey('comment'), isFalse);
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_page_cues_include_prior_source_but_no_future_story",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final run = marginaliaRun(
        fixture,
        [
          request({
            'mode': 'cues',
            'pos': end,
            'page_start': start,
            'page_end': end,
            'persona': 'auto',
          }),
        ],
        {'jev': <String, Object?>{}},
      );
      expect(response(run, 0)['status'], 200);
      final state = obj(calls(run, 'jev').single['state']);
      expect(state['source_before_this_page'], contains('她已经听懂了暗示'));
      expect(state['visible_page_sentences'], {'s1': fixture['quote']});
      expect(
        state['source_before_this_page'],
        isNot(contains(fixture['quote'])),
      );
      expect(jsonEncode(state), isNot(contains('后来真相')));
      expect(jsonEncode(state), isNot(contains('未来事件绝不能出现')));
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_story_prioritizes_page_character_and_related_history",
    () {
      final people = <String, Map<String, Object?>>{
        for (var i = 0; i < 15; i++)
          'p$i': {
            'id': 'p$i',
            'name': '路人$i',
            'aliases': <String>[],
            'n': 100 - i,
            'imp': 1,
            'bio': '',
          },
      };
      people['p14']!.addAll({
        'name': '尼尔',
        'aliases': ['奈尔'],
        'n': 1,
        'bio': '此前藏起了地图',
      });
      final world = <String, Object?>{
        'people': people,
        'events': [
          {
            'who': ['p14'],
            'text': '尼尔曾经收起地图。',
          },
          for (var i = 0; i < 15; i++)
            {
              'who': ['p0'],
              'text': '另一条近期记录$i。',
            },
        ],
        'rels': {
          'old': {'a': 'p14', 'b': 'p0', 'desc': '曾一起寻找入口'},
        },
        'saga': '',
      };
      final focused =
          callPorted('server.marginalia._story', {
                'world': world,
                'focus': '奈尔重新看向地图',
                'limit_people': 12,
              })
              as String;
      expect(focused, contains('尼尔｜'));
      expect(focused, contains('本页别名：奈尔'));
      expect(focused, contains('尼尔曾经收起地图'));
      expect(focused, contains('尼尔—路人0：曾一起寻找入口'));
    },
    skip:
        "Dart implementation of server.marginalia._story is pending (A2, A6); required to check 'story prioritizes page character and related history'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_prior_source_window_is_hard_bounded_at_utf16_cutoff",
    () {
      final prefix = List<String>.filled(3000, '甲').join();
      final text = '$prefix😀已经看到。尚未看到。';
      final book = {
        'blocks': [
          {'k': 'p', 'o': 0, 't': text},
        ],
      };
      final cutoff = _u16('$prefix😀已经看到。');
      final prior =
          callPorted('server.marginalia._source_before', {
                'book': book,
                'pos': cutoff,
                'chars': 2400,
              })
              as String;
      expect(prior.runes.length, lessThanOrEqualTo(2400));
      expect(prior, endsWith('😀已经看到。'));
      expect(prior, isNot(contains('尚未看到')));
    },
    skip:
        "Dart implementation of pipeline.parse.u16, server.marginalia._source_before is pending (A2, A6); required to check 'prior source window is hard bounded at utf16 cutoff'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_clicked_cue_writes_three_distinct_plain_comments_in_parallel",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final payload = {
        'mode': 'auto',
        'pos': end,
        'page_start': start,
        'page_end': end,
        'persona': 'detective',
      };
      final run = marginaliaRun(
        fixture,
        [request(payload), request(payload)],
        {
          'chat': {
            'barrier': {'parties': 3},
            'byPersona': {
              'detective': '她已经听懂了暗示，为什么还把信折起来？',
              'empathy': '这信都被折成一小方了，真不想让人看见吧。',
              'wit': '嘴上什么也没说，手倒挺忙的。',
            },
          },
          'guard': {
            for (final persona in ['detective', 'empathy', 'wit'])
              persona: {'verdict': 'ok', 'p': 0.93},
          },
        },
      );
      expect(
        [
          response(run, 0)['status'],
          response(run, 1)['status'],
          content(run, 1)['cached'],
        ],
        [200, 200, true],
      );
      final chats = calls(run, 'chat');
      expect(chats, hasLength(3));
      expect(run['maximumConcurrentChat'], greaterThanOrEqualTo(3));
      final items = array(content(run, 0)['items']).map(obj).toList();
      expect(items, hasLength(3));
      expect(items.map((item) => item['persona']).toList(), [
        'detective',
        'empathy',
        'wit',
      ]);
      expect(
        items.every(
          (item) =>
              item['quote'] == fixture['quote'] &&
              item['knowledge_cutoff'] == end,
        ),
        isTrue,
      );
      expect(obj(calls(run, 'guard').last['items']).keys.toSet(), {
        'detective',
        'empathy',
        'wit',
      });
      expect(chats.every((chat) => chat['model'] == run['autoModel']), isTrue);
      final systems =
          chats
              .map(
                (chat) =>
                    obj(array(chat['messages']).first)['content']! as String,
              )
              .toList();
      expect(
        systems.map((s) => s.split('这一次的口吻提示：').last).toSet(),
        hasLength(3),
      );
      expect(systems.every((s) => s.contains('不强求句号')), isTrue);
      expect(array(run['cacheRows']), hasLength(1));
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_partial_generation_or_guard_rejection_keeps_only_safe_comments",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final run = marginaliaRun(
        fixture,
        [
          request({
            'mode': 'auto',
            'pos': end,
            'page_start': start,
            'page_end': end,
            'persona': 'detective',
          }),
        ],
        {
          'chat': {
            'byPersona': {
              'detective': {
                'error': {
                  'type': 'RuntimeError',
                  'message': 'provider unavailable',
                },
              },
              'empathy': '手里这封信，她是真不想让别人看见。',
              'wit': '这封信都快被她折没了。',
            },
          },
          'guard': {
            'empathy': {'verdict': 'ok', 'p': 0.9},
            'wit': {'verdict': 'flag', 'p': 0.2},
          },
        },
      );
      expect(response(run, 0)['status'], 200);
      final items = array(content(run, 0)['items']);
      expect(items, hasLength(1));
      expect(obj(items.single)['persona'], 'empathy');
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_invalid_anchor_never_generates",
    () {
      final fixture = storyFixture();
      final start = fixture['start']! as int, end = fixture['end']! as int;
      final run = marginaliaRun(fixture, [
        request({
          'mode': 'manual',
          'pos': end,
          'start': start,
          'end': end + 2,
          'persona': 'empathy',
        }, forbidGenerate: true),
        request({
          'mode': 'auto',
          'pos': end,
          'page_start': 0,
          'page_end': end + 1,
          'persona': 'auto',
        }, forbidGenerate: true),
      ], {});
      expect(
        [response(run, 0)['status'], response(run, 1)['status']],
        [400, 400],
      );
      expect(calls(run, 'chat'), isEmpty);
      expect(calls(run, 'generateMany'), isEmpty);
    },
    skip:
        "Dart server.marginalia and server.app.Handler HTTP owners plus the fixed-clock, revisioned-cache, scripted jev/chat/guard adapter are pending (A2/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_utf16_candidate_offsets_round_trip",
    () {
      const text = '😀她终于笑了。下一句话。';
      final book = {
        'blocks': [
          {'k': 'p', 't': text, 'o': 10},
        ],
      };
      final rows =
          callPorted('server.marginalia._page_candidates', {
                'book': book,
                'start': 10,
                'end': 10 + _u16(text),
              })
              as List<Object?>;
      final first = rows.first as Map<String, Object?>;
      expect(first['start'], 10);
      expect(first['end'], 10 + _u16('😀她终于笑了。'));
      expect(first['quote'], '😀她终于笑了。');
    },
    skip:
        "Dart implementation of pipeline.parse.u16, server.marginalia._page_candidates is pending (A2, A6); required to check 'utf16 candidate offsets round trip'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_prompt_fragments_and_truncated_comments_are_not_published",
    () {
      for (final (input, expected) in <(String, String)>[
        ('、Markdown、表情等。', ''),
        ('争了半天责任，', ''),
        ('嘴上说着随便，这手倒是诚实得很嘛', '嘴上说着随便，这手倒是诚实得很嘛'),
        ('他居然真的信了😂', '他居然真的信了😂'),
        ('这句我真的绷不住(￣▽￣)', '这句我真的绷不住(￣▽￣)'),
      ]) {
        expect(
          callPorted('server.marginalia._clean', {'text': input}),
          expected,
          reason: input,
        );
      }
    },
    skip:
        "Dart implementation of server.marginalia._clean is pending (A2, A6); required to check 'prompt fragments and truncated comments are not published'.",
  );
}
