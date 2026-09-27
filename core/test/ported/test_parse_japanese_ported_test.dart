// Translated Python 1.7.5 parser contracts; enabled when the A2 parse adapter exists.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _parse(String text) =>
    callPorted('pipeline.parse.parse_txt', {
          // The A2 test adapter writes these UTF-8 bytes to book.txt in a
          // temporary directory and invokes the public parse_txt entry point.
          'name': 'book.txt',
          'text': text,
        })
        as Map<String, Object?>;

List<Map<String, Object?>> _rows(Map<String, Object?> book, String field) =>
    (book[field] as List<Object?>).cast<Map<String, Object?>>();

void main() {
  test(
    "tests.test_parse_japanese.JapanesePlainText.test_preface_does_not_swallow_numbered_parts",
    () {
      final preface = List.filled(30, 'この本は雪の結晶について研究したものです。').join();
      final story = List.filled(30, '雪がどのようにできるかを調べていました。').join();
      final book = _parse(
        [
          '雪',
          '第１図版',
          '序',
          preface,
          '第一　雪と人生',
          '一',
          story,
          '二',
          story,
          '第二　「雪の結晶」雑話',
          '一',
          story,
        ].join('\n\n'),
      );
      final chapters = _rows(book, 'chapters');
      final blocks = _rows(book, 'blocks');
      expect(book['lang'], 'ja');
      expect(chapters.firstWhere((c) => c['title'] == '序')['kind'], 'front');
      final body = chapters.where((c) => c['kind'] == 'body').toList();
      expect(body, isNotEmpty);
      expect(
        chapters.any((c) => (c['title'] as String).contains('第一　雪と人生')),
        isTrue,
      );
      expect(
        chapters.any((c) => (c['title'] as String).contains('第二　「雪の結晶」雑話')),
        isTrue,
      );
      expect(chapters.any((c) => c['title'] == '第１図版'), isFalse);
      for (final chapter in body.where(
        (c) => c['title'] == '一' || c['title'] == '二',
      )) {
        final text =
            blocks
                .sublist(chapter['b0'] as int, chapter['b1'] as int)
                .map((block) => block['t'] as String)
                .join();
        expect(text, contains(story));
      }
    },
    skip:
        'A2 pipeline.parse.parse_txt and its UTF-8 fixture adapter are pending.',
  );
  test(
    "tests.test_parse_japanese.JapanesePlainText.test_notebooks_and_narrative_frames_are_chapters",
    () {
      final paragraph = List.filled(30, '私は、その人について何も知らなかったのです。').join();
      final titles = ['はしがき', '第一の手記', '第二の手記', '第三の手記', 'あとがき'];
      final book = _parse(
        [
          '人間失格',
          for (final title in titles) ...[title, paragraph],
        ].join('\n\n'),
      );
      final chapters = _rows(book, 'chapters');
      expect(chapters.skip(1).map((c) => c['title']), titles);
      expect(chapters.skip(1).every((c) => c['kind'] == 'body'), isTrue);
    },
    skip:
        'A2 pipeline.parse.parse_txt and its UTF-8 fixture adapter are pending.',
  );
  test(
    "tests.test_parse_japanese.JapanesePlainText.test_named_upper_middle_lower_parts_preserve_offsets",
    () {
      final paragraph = List.filled(30, '私は先生と呼んでいた人のところへ行きました。😀').join();
      final book = _parse(
        [
          'こころ',
          '上　先生と私',
          '一',
          paragraph,
          '中　両親と私',
          '一',
          paragraph,
          '下　先生と遺書',
          '一',
          paragraph,
        ].join('\n\n'),
      );
      final chapters = _rows(book, 'chapters');
      final blocks = _rows(book, 'blocks');
      for (final title in ['上　先生と私', '中　両親と私', '下　先生と遺書']) {
        expect(
          chapters.any((c) => (c['title'] as String).contains(title)),
          isTrue,
        );
      }
      var offset = 0;
      for (final block in blocks) {
        expect(block['o'], offset);
        offset += (block['t'] as String).codeUnits.length + 1;
      }
      expect(book['len'], offset);
    },
    skip:
        'A2 pipeline.parse.parse_txt and its UTF-16 offset adapter are pending.',
  );
  test(
    "tests.test_parse_japanese.JapanesePlainText.test_chinese_headings_keep_their_existing_structure",
    () {
      final paragraph = List.filled(30, '一个人在屋外看着落下的雪，想起多年前的朋友。').join();
      final book = _parse(
        [
          '书名',
          '序',
          paragraph,
          '第一章 雪',
          paragraph,
          '第二章 人',
          paragraph,
        ].join('\n\n'),
      );
      expect(book['lang'], 'zh');
      expect(_rows(book, 'chapters').map((c) => c['title']), [
        '开始',
        '序',
        '第一章 雪',
        '第二章 人',
      ]);
    },
    skip:
        'A2 pipeline.parse.parse_txt and its UTF-8 fixture adapter are pending.',
  );
}
