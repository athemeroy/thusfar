import 'package:flutter/material.dart';

/// Design tokens from docs/flutter-rewrite/design/spec.json.
///
/// 朱 (zhu) is only for what the AI produced; 石青 (qing) is only for what the
/// reader wrote. Errors use amber and danger, never zhu.
@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.paper,
    required this.sheet,
    required this.raised,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.rule,
    required this.zhu,
    required this.zhuSoft,
    required this.qing,
    required this.qingSoft,
    required this.amber,
    required this.danger,
    required this.ok,
  });

  final Color paper, sheet, raised, ink, ink2, ink3, rule;
  final Color zhu, zhuSoft, qing, qingSoft, amber, danger, ok;

  static const Tokens light = Tokens(
    paper: Color(0xFFF2EDE2),
    sheet: Color(0xFFFBF8F1),
    raised: Color(0xFFFFFFFF),
    ink: Color(0xFF231F1A),
    ink2: Color(0xFF5F574C),
    ink3: Color(0xFF958B7D),
    rule: Color(0xFFE2D9C8),
    zhu: Color(0xFFB23A1F),
    zhuSoft: Color(0xFFF3DDD4),
    qing: Color(0xFF2D5A77),
    qingSoft: Color(0xFFD9E5EC),
    amber: Color(0xFF9A6412),
    danger: Color(0xFFA3261B),
    ok: Color(0xFF3C6B3A),
  );

  static const Tokens night = Tokens(
    paper: Color(0xFF161410),
    sheet: Color(0xFF1E1B16),
    raised: Color(0xFF26221C),
    ink: Color(0xFFDDD4C4),
    ink2: Color(0xFFA99E8C),
    ink3: Color(0xFF766D60),
    rule: Color(0xFF332E26),
    zhu: Color(0xFFE0694B),
    zhuSoft: Color(0xFF3A231B),
    qing: Color(0xFF86AECA),
    qingSoft: Color(0xFF1D2B34),
    amber: Color(0xFFD9A04A),
    danger: Color(0xFFE5715F),
    ok: Color(0xFF8DBA84),
  );

  /// Reading paper colours (纸 · 米 · 青灰 · 白 · 夜).
  static const List<(String, Color)> paperColors = <(String, Color)>[
    ('纸', Color(0xFFF2EDE2)),
    ('米', Color(0xFFF7F1E1)),
    ('青灰', Color(0xFFE7EBE6)),
    ('白', Color(0xFFFBFAF7)),
    ('夜', Color(0xFF161410)),
  ];

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(Tokens? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension TokensContext on BuildContext {
  Tokens get tk => Theme.of(this).extension<Tokens>()!;
}

const String serif = 'NotoSerifSC';
const String display = 'ZCOOLXiaoWei';

/// Motion from the spec.
abstract final class Motion {
  static const Duration page = Duration(milliseconds: 240);
  static const Curve pageCurve = Cubic(0.2, 0, 0, 1);
  static const Duration sheet = Duration(milliseconds: 320);
  static const Duration push = Duration(milliseconds: 220);
  static const Duration toolbar = Duration(milliseconds: 160);
  static const Duration arrive = Duration(milliseconds: 200);
}

ThemeData buildTheme(Brightness brightness) {
  final Tokens t = brightness == Brightness.dark ? Tokens.night : Tokens.light;
  final ColorScheme scheme = ColorScheme(
    brightness: brightness,
    primary: t.ink,
    onPrimary: t.sheet,
    secondary: t.qing,
    onSecondary: t.sheet,
    error: t.danger,
    onError: t.sheet,
    surface: t.sheet,
    onSurface: t.ink,
  );
  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: t.paper,
    extensions: <ThemeExtension<dynamic>>[t],
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.sheet,
      modalBackgroundColor: t.sheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.paper,
      foregroundColor: t.ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: display,
        color: t.ink,
        fontSize: 24,
        height: 1.1,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.sheet,
      surfaceTintColor: Colors.transparent,
      indicatorColor: t.qingSoft,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
        final bool selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? t.qing : t.ink3,
          size: selected ? 24 : 22,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
        final bool selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? t.qing : t.ink3,
          fontSize: selected ? 12 : 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          letterSpacing: 0.2,
        );
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: t.ink3, fontSize: 14),
      labelStyle: TextStyle(color: t.ink2),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: t.rule),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: t.qing, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: t.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: t.danger, width: 1.5),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.ink2,
      textColor: t.ink,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      minVerticalPadding: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    cardTheme: CardThemeData(
      color: t.sheet,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: t.rule.withValues(alpha: 0.78)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: t.ink,
        foregroundColor: t.sheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.qing,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.zhu,
      linearTrackColor: t.rule,
      circularTrackColor: t.rule,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.ink,
      contentTextStyle: TextStyle(color: t.sheet, fontSize: 15),
      actionTextColor: t.zhuSoft,
      behavior: SnackBarBehavior.floating,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: t.ink, displayColor: t.ink),
  );
}

/// A 999-radius pill button used across the app.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.onTap,
    this.filled = false,
    this.color,
    this.icon,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final Color c = color ?? t.ink;
    return Material(
      color: filled ? c : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: filled ? c : t.rule)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 10 : 16,
            vertical: dense ? 4 : 10,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: dense ? 14 : 18, color: filled ? t.sheet : c),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: dense ? 12 : 15,
                  color: filled ? t.sheet : c,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small label chip such as 「截至第 16 页」.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.onTap});

  final String text;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? context.tk.ink3;
    final Widget body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: c.withValues(alpha: 0.6))),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: c,
          letterSpacing: 0.66,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
    return onTap == null
        ? body
        : GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: body,
          );
  }
}

/// The circular avatar with a person's initial on their ink.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.color,
    this.size = 22,
    this.isNew = false,
  });

  final String name;
  final String color;
  final double size;
  final bool isNew;

  @override
  Widget build(BuildContext context) {
    final Color bg = Color(int.parse('FF${color.substring(1)}', radix: 16));
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: context.tk.sheet,
                width: size > 30 ? 2 : 1.5,
              ),
            ),
            child: Text(
              initial(name),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.48,
                height: 1.0,
                fontFamily: display,
              ),
            ),
          ),
          if (isNew)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: size * 0.32,
                height: size * 0.32,
                decoration: BoxDecoration(
                  color: context.tk.zhu,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.tk.sheet),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final RegExp _westernPrefix = RegExp(
  r'^(?:(?:mr|mrs|miss|ms|dr|sir|lady|lord|the|a|an|old|young|little|uncle|aunt|captain|master)\.?\s+)+',
  caseSensitive: false,
);

/// `util.js initial`: surname initial for Western names, first character otherwise.
String initial(String name) {
  String s = name.replaceFirst(RegExp('^[“"「（(]'), '').trim();
  if (s.isEmpty) return '?';
  if (RegExp('^[A-Za-z]').hasMatch(s)) {
    final List<String> words = s
        .replaceFirst(_westernPrefix, '')
        .split(RegExp(r'\s+'));
    s = words.isEmpty || words.last.isEmpty ? s : words.last;
    final RegExpMatch? m = RegExp('[A-Za-z]').firstMatch(s);
    return (m?.group(0) ?? '?').toUpperCase();
  }
  return String.fromCharCode(s.runes.first);
}
