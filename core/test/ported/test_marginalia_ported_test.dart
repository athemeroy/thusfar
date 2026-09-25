// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

import 'contract_invoker.dart';

int _u16(String text) => callPorted('pipeline.parse.u16', {'s': text}) as int;

void main() {
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_distinct_prefetch_pages_run_concurrently_and_keep_both_cache_rows",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_distinct_prefetch_pages_run_concurrently_and_keep_both_cache_rows",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'distinct prefetch pages run concurrently and keep both cache rows'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_manual_comment_uses_only_text_through_anchor_and_reuses_cache",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_manual_comment_uses_only_text_through_anchor_and_reuses_cache",
    ),
    skip:
        "Dart implementation of server.app.cached_json, server.app.wjson is pending (A2, A6); required to check 'manual comment uses only text through anchor and reuses cache'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_auto_reaction_uses_only_visible_page_and_reuses_cache",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_auto_reaction_uses_only_visible_page_and_reuses_cache",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'auto reaction uses only visible page and reuses cache'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_page_cues_call_jev_once_but_never_generate_prose_until_tapped",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_page_cues_call_jev_once_but_never_generate_prose_until_tapped",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'page cues call jev once but never generate prose until tapped'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_page_cues_include_prior_source_but_no_future_story",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_page_cues_include_prior_source_but_no_future_story",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'page cues include prior source but no future story'.",
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
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_clicked_cue_writes_three_distinct_plain_comments_in_parallel",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'clicked cue writes three distinct plain comments in parallel'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_partial_generation_or_guard_rejection_keeps_only_safe_comments",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_partial_generation_or_guard_rejection_keeps_only_safe_comments",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'partial generation or guard rejection keeps only safe comments'.",
  );
  test(
    "tests.test_marginalia.MarginaliaHTTP.test_invalid_anchor_never_generates",
    () => fail(
      "Dart port not implemented: tests.test_marginalia.MarginaliaHTTP.test_invalid_anchor_never_generates",
    ),
    skip:
        "Dart implementation of pipeline.parse, server.app, server.marginalia is pending (A2, A6); required to check 'invalid anchor never generates'.",
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
