/// What a model costs and how fast it is, for every part of the product.
///
/// Prices are CNY per million tokens. `mult` is the channel multiplier a
/// gateway may apply to the list price. `rate` is measured from real books.
library;

import 'dart:convert';

import '../env.dart';
import '../py/py_compat.dart';

typedef Pair = (double, double);

/// A model's price row: list price, channel multiplier, optional official.
final class Price {
  const Price(this.price, this.mult, [this.official]);

  final Pair price;
  final Pair mult;
  final Pair? official;
}

const Map<String, Price> prices = <String, Price>{
  'gpt-5.6-terra': Price((2.0, 12.0), (0.25, 0.4)),
  'deepseek-flash': Price((1.056, 4.224), (1.0, 1.0), (1.0, 4.0)),
  'deepseek-v3.2': Price((0.96, 1.44), (1.0, 1.0)),
  'deepseek-v4-pro': Price((4.752, 14.256), (1.0, 1.0)),
  'claude-opus-5': Price((35.0, 175.0), (1.0, 1.0)),
  'gemini-2.5-flash-lite': Price((0.08, 0.32), (0.5, 0.5), (0.72, 2.88)),
  'gemini-3.1-flash-lite-preview': Price((0.20, 0.60), (0.5, 0.5), (
    0.72,
    2.88,
  )),
  'gpt-4.1-nano': Price((0.08, 0.32), (1.0, 1.0)),
  'gpt-4o-mini': Price((0.12, 0.48), (1.0, 1.0)),
  'qwen3-4b': Price((0.08, 0.48), (1.0, 1.0)),
  'gpt-oss-20b': Price((0.10, 0.38), (1.0, 1.0)),
};

/// $0.042 per million input tokens, in CNY.
const double jevPrice = 0.042 * 7.2;

double? _pyFloat(Object? value) {
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1.0 : 0.0;
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// What the person running this actually pays, from `MODEL_PRICES`.
Map<String, Price> overrides() {
  final Object? raw;
  try {
    final String text = environ['MODEL_PRICES'] ?? '';
    raw = jsonDecode(text.isEmpty ? '{}' : text);
  } on FormatException {
    return <String, Price>{};
  }
  if (raw is! Map<String, Object?>) return <String, Price>{};
  final Map<String, Price> out = <String, Price>{};
  for (final MapEntry<String, Object?> e in raw.entries) {
    final Object? v = e.value;
    if (v is List<Object?> && v.length == 2) {
      final double? a = _pyFloat(v[0]);
      final double? b = _pyFloat(v[1]);
      if (a == null || b == null) return <String, Price>{};
      out[e.key] = Price((a, b), (1.0, 1.0));
    }
  }
  return out;
}

/// The reader's own price if they gave one, else the measured table.
Price priceOf(String model, {bool official = false}) {
  final Price? mine = overrides()[model];
  if (mine != null) return mine;
  final Price p = prices[model] ?? const Price((2.0, 12.0), (1.0, 1.0));
  if (official && p.official != null) return Price(p.official!, (1.0, 1.0));
  return p;
}

double judgePrice() {
  final String? raw = environ['JEV_PRICE_OVERRIDE'];
  if (raw == null) return jevPrice;
  return double.tryParse(raw.trim()) ?? jevPrice;
}

/// Tokens (input, output) and minutes per 10k characters of a book.
final class Rate {
  const Rate(this.tokens, this.minutes);

  final Pair tokens;
  final double minutes;
}

const Rate defaultRate = Rate((38000, 16000), 0.46);
const int defaultJudgeChars = 25000;
const Map<String, Rate> rates = <String, Rate>{
  'gpt-5.6-terra': Rate((38000, 16000), 0.46),
  'deepseek-flash': Rate((17500, 7000), 0.17),
  'gemini-2.5-flash-lite': Rate((38000, 6500), 0.06),
  'gemini-3.1-flash-lite-preview': Rate((38000, 6500), 0.06),
};

/// Latin text is about three characters per Chinese character.
const double latinFactor = 0.35;
const List<String?> cjk = <String?>['zh', 'ja', null, ''];

String _firstPart(String model) => model.split('+').first;

String modelNow() {
  String pick(String key) => environ[key] ?? '';
  final String chosen =
      pick('LOCAL_MODEL').isNotEmpty
          ? pick('LOCAL_MODEL')
          : pick('EXTRACT_MODEL').isNotEmpty
          ? pick('EXTRACT_MODEL')
          : 'deepseek-flash+nothink';
  return _firstPart(chosen);
}

/// What reading this book with the AI will take: minutes and a CNY range.
Map<String, Object?> estimate(
  int chars, {
  String? model,
  String? lang = 'zh',
  bool judge = true,
  bool official = false,
}) {
  final String name = _firstPart(
    model == null || model.isEmpty ? modelNow() : model,
  );
  final Rate rate = rates[name] ?? defaultRate;
  if (!prices.containsKey(name) && !overrides().containsKey(name)) {
    return <String, Object?>{
      'model': name,
      'minutes': null,
      'low': null,
      'high': null,
    };
  }
  final Price price = priceOf(name, official: official);
  final double units =
      (chars < 0 ? 0 : chars) / 10000 * (cjk.contains(lang) ? 1 : latinFactor);
  final double tin = rate.tokens.$1 * units / 1e6;
  final double tout = rate.tokens.$2 * units / 1e6;
  final double base = tin * price.price.$1 + tout * price.price.$2;
  double lo = base * price.mult.$1;
  double hi = base * price.mult.$2;
  if (judge &&
      !<String>[
        'free-only',
        'free',
      ].contains(environ['JEV_ROUTE'] ?? 'free-only')) {
    final double jevTokens = units * defaultJudgeChars / 1.5 / 1e6;
    lo += jevTokens * judgePrice();
    hi += jevTokens * judgePrice();
  }
  return <String, Object?>{
    'model': name,
    'minutes': PyCompat.round(units * rate.minutes),
    'low': PyCompat.roundDigits(lo, 2),
    'high': PyCompat.roundDigits(hi, 2),
  };
}

num _num(Object? value) => (value as num?) ?? 0;

/// CNY range actually spent, from a book's recorded usage.
(double, double) costOf(Map<String, Object?> usage) {
  double lo = 0.0;
  double hi = 0.0;
  final Map<String, Object?> byModel =
      (usage['by_model'] as Map<String, Object?>?) ?? const {};
  for (final MapEntry<String, Object?> e in byModel.entries) {
    final Price p = priceOf(_firstPart(e.key));
    final Map<String, Object?> u = e.value! as Map<String, Object?>;
    final double c =
        (_num(u['prompt']) * p.price.$1 + _num(u['completion']) * p.price.$2) /
        1e6;
    lo += c * p.mult.$1;
    hi += c * p.mult.$2;
  }
  final Map<String, Object?> jev =
      (usage['jev'] as Map<String, Object?>?) ?? const {};
  final Object? billed =
      jev.containsKey('paid_chars') ? jev['paid_chars'] : jev['chars'];
  if (billed is num && billed != 0) {
    final double c = billed / 1.5 / 1e6 * judgePrice();
    lo += c;
    hi += c;
  }
  return (PyCompat.roundDigits(lo, 2), PyCompat.roundDigits(hi, 2));
}
