/// Book language and card language.
///
/// The pipeline was built on Chinese books; for Western books the model gets
/// the same Chinese instructions plus a language note, quotes stay verbatim,
/// and every character limit is scaled.
library;

import '../env.dart';
import '../py/py_compat.dart';

final RegExp _latin = RegExp('[A-Za-z]');
final RegExp _cjk = RegExp('[㐀-鿿]');

String bookLang(Map<String, Object?> book) {
  final Object? lang = book['lang'];
  if (lang is String && lang.isNotEmpty) return lang;
  final List<Object?> blocks = (book['blocks'] as List<Object?>?) ?? const [];
  final StringBuffer joined = StringBuffer();
  for (final Object? b in blocks.take(400)) {
    joined.write((b! as Map<String, Object?>)['t']);
  }
  final String sample = PyCompat.slice(joined.toString(), null, 40000);
  final int latin = _latin.allMatches(sample).length;
  final int cjk = _cjk.allMatches(sample).length;
  return latin > 20 * (cjk < 1 ? 1 : cjk) ? 'en' : 'zh';
}

String cardLang(Map<String, Object?> book) {
  final String? fromEnv = environ['CARD_LANG'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final Object? stored = book['card_lang'];
  if (stored is String && stored.isNotEmpty) return stored;
  return bookLang(book);
}

/// Multiplier for character limits on generated text.
int scale(Map<String, Object?> book) => cardLang(book) == 'en' ? 3 : 1;

/// About the same number of tokens per segment in both scripts.
int segChars(Map<String, Object?> book) => bookLang(book) == 'en' ? 9000 : 3200;

/// Appended to the phase-1 instructions.
String localNote(Map<String, Object?> book) {
  if (bookLang(book) != 'en') return '';
  String out =
      '\n\n【语言】这本书是英文原著。quote 必须逐字复制英文原文（5～25 个英文单词）；names 按原文写法'
      '（如 Mr. Utterson、Dr. Jekyll、Poole），泛称和称谓（the lawyer、the maid、Sir、the old gentleman、his friend）前加 *。';
  if (cardLang(book) == 'en') {
    out +=
        '所有要写的文字（role、text、value、desc、b_is、a_is、why）一律用英文写；字数要求按英文单词计。'
        'facts 的 key 用：identity|occupation|residence|age|appearance|personality|situation|alive。';
  } else {
    out += '所有要写的文字用中文写，人名保留原文拼写。';
  }
  return out;
}

/// Appended to recap, story-so-far and biography prompts.
String outNote(Map<String, Object?> book) {
  if (cardLang(book) == 'en') {
    return '\n\n【输出语言】用英文写，字数要求按英文单词计（一句话身份 ≤12 个词）。';
  }
  if (bookLang(book) == 'en') return '\n\n【输出语言】用中文写，人名保留原文拼写。';
  return '';
}

const List<String> lifeKeys = <String>[
  '生死',
  '婚恋',
  'alive',
  'life',
  'death',
  'marriage',
  'married',
];
