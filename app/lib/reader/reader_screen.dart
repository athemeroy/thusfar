import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart';
import 'package:thusfar_core/ask.dart' as ask;

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/prefs.dart';
import '../data/processing.dart';
import '../data/seen.dart';
import '../sheets/ask_sheet.dart';
import '../sheets/book_sheet.dart';
import '../sheets/common.dart';
import '../sheets/marginalia_sheet.dart';
import '../sheets/note_editor.dart';
import '../sheets/people_sheet.dart';
import '../sheets/person_sheet.dart';
import '../sheets/recap_sheet.dart';
import '../sheets/search_sheet.dart';
import '../sheets/sheet_host.dart';
import '../sheets/toc_sheet.dart';
import '../sheets/typography_sheet.dart';
import '../ui/theme.dart';
import '../sheets/footnotes_sheet.dart';
import 'page_body.dart';
import 'paginator.dart';
import 'reader_controller.dart';

/// S04 阅读页 with its toolbar (S04c), selection (S06) and drawers.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.library,
    required this.entry,
    required this.prefs,
    required this.settings,
    required this.processing,
    required this.onModelSettings,
    required this.onExport,
    this.openAt,
    this.openNotes = false,
  });

  final Library library;
  final BookEntry entry;
  final Prefs prefs;
  final ModelSettings settings;
  final BookProcessing processing;
  final Future<void> Function() onModelSettings;
  final Future<void> Function(BookEntry) onExport;

  /// Opens at this offset and offers 「回到第 N 页」 to where the reader was.
  final int? openAt;
  final bool openNotes;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final BookData book = BookData.open(widget.entry);
  late final ReaderController c = ReaderController(
    library: widget.library,
    book: book,
  );
  PageController? pc;
  PageSpec? spec;
  bool _sheetOpen = false;
  Offset? _pressAt;
  int? _anchor;
  Timer? _flashTimer;
  final FocusNode _focus = FocusNode();
  int? _drag;
  bool _whoIsActive = false;
  bool _whoIsLoading = false;
  Json? _whoIsResult;
  String? _whoIsWord;

  @override
  void initState() {
    super.initState();
    widget.prefs.addListener(_relayout);
    book.notes.addListener(_repaint);
    c.addListener(_repaint);
    widget.library.addListener(_refreshKnowledge);
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_relayout);
    book.notes.removeListener(_repaint);
    c.removeListener(_repaint);
    widget.library.removeListener(_refreshKnowledge);
    c.dispose();
    book.notes.dispose();
    book.dispose();
    _flashTimer?.cancel();
    pc?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refreshKnowledge() {
    if (book.refreshKnowledge()) c.touch();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _relayout() {
    spec = null;
    if (mounted) setState(() {});
  }

  int get _initialOffset {
    final Progress? p = widget.library.progressOf(book.id);
    return p?.pos ??
        book.chapters
            .firstWhere(
              (Chapter ch) => ch.kind == 'body',
              orElse: () => book.chapters.first,
            )
            .o0;
  }

  void _ensureLayout(Size area, Tokens t) {
    final Prefs prefs = widget.prefs;
    final PageSpec next = PageSpec(
      width: area.width,
      height: area.height,
      fontSize: prefs.fontSize,
      lineHeight: prefs.lineHeight,
      fontFamily: prefs.fontFamily,
      color: _ink(t),
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (spec == next && c.pager != null) return;
    final bool first = c.pager == null;
    final int keep = first ? (widget.openAt ?? _initialOffset) : c.start;
    spec = next;
    c.layout(Paginator(book, next), keep);
    if (first && widget.openAt != null) {
      c.returnTo = _initialOffset;
      c.flash = (widget.openAt!, widget.openAt! + 1);
    }
    pc?.dispose();
    pc = PageController(initialPage: ReaderController.base);
    if (first && widget.openNotes) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sheet(TocPage(link: link, tab: 2), full: true);
      });
    }
  }

  Color _paper(Tokens t) =>
      widget.prefs.paper == 4 || Theme.of(context).brightness == Brightness.dark
      ? Tokens.night.paper
      : Tokens.paperColors[widget.prefs.paper].$2;

  bool get _night =>
      widget.prefs.paper == 4 ||
      Theme.of(context).brightness == Brightness.dark;

  Color _ink(Tokens t) => _night ? Tokens.night.ink : Tokens.light.ink;

  ReaderLink get link =>
      ReaderLink(c: c, jump: _jumpFromSheet, openAsk: _openAsk);

  void _jumpFromSheet(int offset, {(int, int)? highlight}) {
    Navigator.of(context).popUntil((Route<dynamic> r) => r is PageRoute);
    _jump(offset, highlight: highlight);
  }

  void _jump(int offset, {(int, int)? highlight, bool remember = true}) {
    final int index = c.jump(
      offset,
      remember: remember,
      highlight: highlight ?? (offset, offset + 1),
    );
    pc?.dispose();
    pc = PageController(initialPage: index);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), c.clearFlash);
    setState(() {});
  }

  Future<void> _sheet(
    Widget page, {
    double initial = 0.45,
    bool full = false,
    Offset? anchorPoint,
  }) async {
    final bool restoreToolbar = c.toolbar;
    c.setToolbar(false);
    _sheetOpen = true;
    try {
      await openSheet<void>(
        context,
        page,
        initial: initial,
        full: full,
        anchorPoint: anchorPoint,
      );
    } finally {
      _sheetOpen = false;
      if (mounted) {
        if (restoreToolbar) c.setToolbar(true);
        setState(() {});
      }
    }
  }

  void _openPerson(String id) {
    HapticFeedback.lightImpact();
    _sheet(PersonPage(link: link, id: id));
  }

  void _clearSelection() {
    c.select(null);
    if (_whoIsActive) {
      setState(() {
        _whoIsActive = false;
        _whoIsLoading = false;
        _whoIsResult = null;
        _whoIsWord = null;
      });
    }
  }

  Future<void> _identifyWho(int s, int e) async {
    HapticFeedback.lightImpact();
    final String word = book.textBetween(s, e).trim();
    if (word.isEmpty) return;
    setState(() {
      _whoIsActive = true;
      _whoIsLoading = true;
      _whoIsResult = null;
      _whoIsWord = word;
    });

    try {
      final Json res = await ask.whoIs(
        book.book,
        book.records,
        c.cutoff,
        s,
        e,
      );
      if (!mounted) return;
      setState(() {
        _whoIsLoading = false;
        _whoIsResult = res;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _whoIsLoading = false;
        _whoIsResult = <String, Object?>{
          'ok': false,
          'word': word,
        };
      });
    }
  }

  void _openAsk({String? prefill, String? quote, Offset? anchorPoint}) =>
      _sheet(
        AskPage(link: link, prefill: prefill, quote: quote),
        full: true,
        anchorPoint: anchorPoint,
      );

  Offset? _foldableAnchor(BuildContext context, {bool lowerPane = false}) {
    final MediaQueryData media = MediaQuery.of(context);
    final DisplayFeature? vertical = media.displayFeatures
        .where(
          (DisplayFeature feature) =>
              feature.bounds.height >= media.size.height * .85 &&
              feature.bounds.width < media.size.width * .4,
        )
        .firstOrNull;
    if (vertical != null) {
      return Offset(
        vertical.bounds.right + (media.size.width - vertical.bounds.right) / 2,
        media.size.height / 2,
      );
    }
    final DisplayFeature? horizontal = media.displayFeatures
        .where(
          (DisplayFeature feature) =>
              feature.bounds.width >= media.size.width * .85 &&
              feature.bounds.height < media.size.height * .4,
        )
        .firstOrNull;
    if (horizontal == null) return null;
    return Offset(
      media.size.width / 2,
      lowerPane
          ? horizontal.bounds.bottom +
                (media.size.height - horizontal.bounds.bottom) / 2
          : horizontal.bounds.top / 2,
    );
  }

  void _startProcessing() {
    Navigator.of(context).popUntil((Route<dynamic> r) => r is PageRoute);
    _openBookSheet(focus: true);
  }

  void _openBookSheet({bool focus = false}) {
    c.setToolbar(false);
    BookSheet.open(
      context,
      BookSheet(
        library: widget.library,
        entry: widget.entry,
        settings: widget.settings,
        processing: widget.processing,
        onRemoved: () {
          if (mounted) Navigator.of(context).pop();
        },
        onRead: () => Navigator.of(context).pop(),
        onNotes: () {
          Navigator.of(context).pop();
          _sheet(TocPage(link: link, tab: 2), full: true);
        },
        onModelSettings: widget.onModelSettings,
        onExport: () => widget.onExport(widget.entry),
        focusProcessing: focus,
      ),
    );
  }

  void _turn(int delta) {
    final PageController? p = pc;
    if (p == null || !p.hasClients) return;
    if (c.pageAt(c.currentIndex + delta) == null) return;
    c.select(null);
    if (widget.prefs.anim == PageAnim.none ||
        MediaQuery.of(context).disableAnimations) {
      p.jumpToPage(c.currentIndex + delta);
    } else {
      p.animateToPage(
        c.currentIndex + delta,
        duration: Motion.page,
        curve: Motion.pageCurve,
      );
    }
  }

  void _onPageChanged(int index) {
    final int before = c.chapter;
    c.onPage(index);
    SeenStore.instance.maxRead(book.id, c.cutoff);
    if (c.chapter != before) HapticFeedback.lightImpact();
  }

  // ---------------------------------------------------------------- selection

  int? _hitOffset(Offset local) {
    final PageData? page = c.page;
    final Paginator? p = c.pager;
    if (page == null || p == null) return null;
    double y = 0;
    for (final Frag f in page.frags) {
      final double h = f.lines * p.spec.line;
      if (local.dy >= y && local.dy < y + h && !f.image) {
        final Block b = book.blocks[f.block];
        final TextPainter tp = p.painterFor(b);
        final int shift = b.kind == 'h' ? 0 : indentShift;
        final int pos =
            tp
                .getPositionForOffset(Offset(local.dx, f.top + (local.dy - y)))
                .offset -
            shift;
        tp.dispose();
        return b.o + pos.clamp(f.start, math.max(f.start, f.end - 1));
      }
      y += h;
    }
    return null;
  }

  static final RegExp _stop = RegExp(r'[。！？!?；;，,、：:“”「」『』（）()\s]');

  (int, int) _wordAt(int offset) {
    final World? w = c.world;
    if (w != null) {
      for (final Mention m in book.mentions(c.chapter)) {
        if (m.start <= offset && offset < m.end && w.person(m.id) != null) {
          return (m.start, m.end);
        }
      }
    }
    final Block b = book.blocks[book.blockAt(offset)];
    final String t = b.text;
    int i = offset - b.o;
    int s = i;
    int e = i;
    while (s > 0 && !_stop.hasMatch(t[s - 1]) && i - s < 20) {
      s--;
    }
    while (e < t.length && !_stop.hasMatch(t[e]) && e - i < 20) {
      e++;
    }
    if (e <= s) e = math.min(t.length, s + 1);
    return (b.o + s, b.o + e);
  }

  void _longPress(LongPressStartDetails d) {
    final int? at = _hitOffset(d.localPosition);
    if (at == null) return;
    HapticFeedback.mediumImpact();
    _pressAt = d.localPosition;
    final (int s, int e) = _wordAt(at);
    c.select((s, e));
    _anchor = c.selection?.$1;
  }

  void _longPressMove(LongPressMoveUpdateDetails d) {
    final int? at = _hitOffset(d.localPosition);
    final int? a = _anchor;
    if (at == null || a == null || c.selection == null) return;
    HapticFeedback.selectionClick();
    if (_whoIsActive) {
      _whoIsActive = false;
      _whoIsResult = null;
      _whoIsLoading = false;
    }
    c.select(
      at >= a ? (a, math.max(at + 1, c.selection!.$2)) : (at, c.selection!.$2),
      anchor: a,
    );
  }

  bool _changeNote(void Function() action) {
    try {
      action();
      return true;
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is PyException ? error.message : '摘记未能保存，请检查存储空间后重试',
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _excerpt() async {
    HapticFeedback.lightImpact();
    final (int s, int e) = c.selection!;
    late Json item;
    if (!_changeNote(() {
      item = book.notes.save(kind: 'note', start: s, end: e, cutoff: c.cutoff);
    })) {
      return;
    }
    c.select(null);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: const Text('已摘录'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            HapticFeedback.lightImpact();
            BookData? reopened;
            try {
              final NoteStore store = mounted
                  ? book.notes
                  : (reopened = BookData.open(widget.entry)).notes;
              store.delete(item);
            } on Object catch (error) {
              if (messenger.mounted) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      error is PyException
                          ? error.message
                          : '撤销未能完成，请重新打开摘记后重试',
                    ),
                  ),
                );
              }
            } finally {
              reopened?.notes.dispose();
              reopened?.dispose();
            }
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final MediaQueryData mq = MediaQuery.of(context);
    final Color paper = _paper(t);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: paper,
        statusBarIconBrightness: _night ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: paper,
        systemNavigationBarIconBrightness: _night
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: t.rule,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
      child: PopScope(
        canPop: c.selection == null && !c.toolbar,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (didPop) return;
          if (c.selection != null) {
            c.select(null);
          } else if (c.toolbar) {
            c.setToolbar(false);
          }
        },
        child: Theme(
          data: buildTheme(
            _night ? Brightness.dark : Theme.of(context).brightness,
          ),
          child: Builder(
            builder: (BuildContext context) => Scaffold(
              backgroundColor: paper,
              resizeToAvoidBottomInset: false,
              body: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  final DisplayFeature? verticalHinge = mq.displayFeatures
                      .where(
                        (DisplayFeature feature) =>
                            feature.bounds.height >= box.maxHeight * .85 &&
                            feature.bounds.width < box.maxWidth * .4,
                      )
                      .firstOrNull;
                  final DisplayFeature? horizontalHinge = mq.displayFeatures
                      .where(
                        (DisplayFeature feature) =>
                            feature.bounds.width >= box.maxWidth * .85 &&
                            feature.bounds.height < box.maxHeight * .4,
                      )
                      .firstOrNull;
                  if (verticalHinge != null) {
                    final double leftWidth = verticalHinge.bounds.left
                        .clamp(0, box.maxWidth)
                        .toDouble();
                    final double right = verticalHinge.bounds.right
                        .clamp(leftWidth, box.maxWidth)
                        .toDouble();
                    return Row(
                      children: <Widget>[
                        SizedBox(
                          width: leftWidth,
                          height: box.maxHeight,
                          child: _readerPane(context, paper),
                        ),
                        SizedBox(width: verticalHinge.bounds.width),
                        SizedBox(
                          width: box.maxWidth - right,
                          height: box.maxHeight,
                          child: _foldableReaderPanel(context),
                        ),
                      ],
                    );
                  }
                  if (horizontalHinge != null) {
                    final double top = horizontalHinge.bounds.top
                        .clamp(0, box.maxHeight)
                        .toDouble();
                    final double hingeBottom = horizontalHinge.bounds.bottom
                        .clamp(top, box.maxHeight)
                        .toDouble();
                    return Column(
                      children: <Widget>[
                        SizedBox(
                          width: box.maxWidth,
                          height: top,
                          child: _readerPane(context, paper),
                        ),
                        SizedBox(
                          width: box.maxWidth,
                          height: horizontalHinge.bounds.height,
                          child: ColoredBox(color: paper),
                        ),
                        SizedBox(
                          width: box.maxWidth,
                          height: box.maxHeight - hingeBottom,
                          child: _foldableControls(context),
                        ),
                      ],
                    );
                  }
                  return _readerPane(context, paper);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  static final Set<LogicalKeyboardKey> _nextKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.space,
  };
  static final Set<LogicalKeyboardKey> _previousKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.pageUp,
  };
  DateTime _lastWheelTurn = DateTime.fromMillisecondsSinceEpoch(0);

  /// A mouse wheel or trackpad scroll turns one page per gesture; the
  /// short pause stops one flick from skipping a whole chapter.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _sheetOpen) return;
    final double dy = event.scrollDelta.dy;
    if (dy.abs() < 4) return;
    final DateTime now = DateTime.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 350)) {
      return;
    }
    _lastWheelTurn = now;
    _turn(dy > 0 ? 1 : -1);
  }

  Widget _readerPane(BuildContext context, Color paper) {
    return Listener(
      onPointerSignal: _wheel,
      child: _readerFocus(context, paper),
    );
  }

  Widget _readerFocus(BuildContext context, Color paper) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (FocusNode _, KeyEvent e) {
        if (_sheetOpen || e is KeyUpEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          if (c.selection != null || _whoIsActive) {
            _clearSelection();
            return KeyEventResult.handled;
          }
          if (c.toolbar) {
            c.setToolbar(false);
            return KeyEventResult.handled;
          }
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        // Computers: arrows, space and page keys turn pages.
        if (_nextKeys.contains(e.logicalKey)) {
          _turn(1);
          return KeyEventResult.handled;
        }
        if (_previousKeys.contains(e.logicalKey)) {
          _turn(-1);
          return KeyEventResult.handled;
        }
        if (!widget.prefs.volumeKeys) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
          _turn(1);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
          _turn(-1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          // Modal editors handle their own keyboard insets. Keep the book's
          // geometry fixed while the IME animates or the device changes posture.
          final EdgeInsets pagePadding = MediaQuery.viewPaddingOf(context);
          final double top = pagePadding.top + 48;
          final double bottom = pagePadding.bottom + 56;
          final double pageWidth = math.min(560, box.maxWidth - 48);
          final double pageLeft = (box.maxWidth - pageWidth) / 2;
          final Size area = Size(
            pageWidth,
            math.max(1, box.maxHeight - top - bottom),
          );
          _ensureLayout(area, context.tk);
          return Stack(
            children: <Widget>[
              Positioned(
                left: pageLeft,
                width: pageWidth,
                top: top,
                height: area.height,
                child: _pages(context, paper),
              ),
              Positioned(
                left: pageLeft,
                width: pageWidth,
                top: pagePadding.top + 10,
                height: 28,
                child: _header(context),
              ),
              Positioned(
                left: pageLeft,
                width: pageWidth,
                bottom: pagePadding.bottom + 6,
                height: 44,
                child: _footer(context),
              ),
              if (book.notes.bookmarkIn(c.start, c.cutoff) != null)
                Positioned(
                  left: pageLeft + pageWidth - 16,
                  top: 0,
                  child: _ribbon(context),
                ),
              if (c.returnTo != null)
                Positioned(
                  left: pageLeft,
                  right: pageLeft,
                  bottom: pagePadding.bottom + 48,
                  child: Center(child: _returnPill(context)),
                ),
              if (c.selection != null) _selectionBar(context, top),
              Positioned(
                left: pageLeft,
                right: pageLeft,
                top: 0,
                bottom: 0,
                child: _toolbar(context),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _foldableReaderPanel(BuildContext context) {
    final Tokens t = context.tk;
    final double progress = book.length == 0 ? 0 : c.cutoff / book.length;
    final String chapter = c.page == null ? '' : book.chapters[c.chapter].title;
    final int currentPage = c.pager == null ? 1 : link.pageNo(c.start);
    Widget action(String label, IconData icon, VoidCallback onPressed) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon, size: 19),
              label: Text(label),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                alignment: Alignment.centerLeft,
                foregroundColor: t.ink,
                side: BorderSide(color: t.rule),
              ),
            ),
          ),
        );
    return ColoredBox(
      color: t.sheet,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('正在阅读', style: TextStyle(fontSize: 12, color: t.ink3)),
                const SizedBox(height: 8),
                Text(
                  widget.entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: display,
                    fontSize: 24,
                    height: 1.2,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$chapter · 第 $currentPage 页',
                  style: TextStyle(fontSize: 13, color: t.ink2),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: progress, minHeight: 4),
                ),
                const SizedBox(height: 24),
                action('目录与书签', Icons.list_alt, () {
                  _sheet(
                    TocPage(link: link),
                    full: true,
                    anchorPoint: _foldableAnchor(context),
                  );
                }),
                action('人物与关系', Icons.hub_outlined, () {
                  _sheet(
                    PeoplePage(link: link, tab: 3),
                    full: true,
                    anchorPoint: _foldableAnchor(context),
                  );
                }),
                action('本章前情', Icons.history_edu, () {
                  _sheet(
                    RecapPage(link: link),
                    full: true,
                    anchorPoint: _foldableAnchor(context),
                  );
                }),
                action('问这本书', Icons.question_answer_outlined, () {
                  _openAsk(anchorPoint: _foldableAnchor(context));
                }),
                action('阅读排版', Icons.text_fields, () {
                  openTypography(context, widget.prefs);
                }),
                const Divider(height: 24),
                Row(
                  children: <Widget>[
                    IconButton.filledTonal(
                      tooltip: '上一页',
                      onPressed: () => _turn(-1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    const Spacer(),
                    Text('翻页', style: TextStyle(color: t.ink3)),
                    const Spacer(),
                    IconButton.filledTonal(
                      tooltip: '下一页',
                      onPressed: () => _turn(1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _foldableControls(BuildContext context) {
    final Tokens t = context.tk;
    Widget control(String label, IconData icon, VoidCallback onPressed) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: OutlinedButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                onPressed();
              },
              icon: Icon(icon, size: 18),
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: t.ink,
                side: BorderSide(color: t.rule),
              ),
            ),
          ),
        );
    return ColoredBox(
      color: t.sheet,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            children: <Widget>[
              Text(
                widget.entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 19,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  control('上一页', Icons.chevron_left, () => _turn(-1)),
                  control('工具栏', Icons.menu, () => c.setToolbar(!c.toolbar)),
                  control('下一页', Icons.chevron_right, () => _turn(1)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  control('目录', Icons.list_alt, () {
                    _sheet(
                      TocPage(link: link),
                      full: true,
                      anchorPoint: _foldableAnchor(context, lowerPane: true),
                    );
                  }),
                  control('人物', Icons.hub_outlined, () {
                    _sheet(
                      PeoplePage(link: link, tab: 3),
                      full: true,
                      anchorPoint: _foldableAnchor(context, lowerPane: true),
                    );
                  }),
                  control('问书', Icons.question_answer_outlined, () {
                    _openAsk(
                      anchorPoint: _foldableAnchor(context, lowerPane: true),
                    );
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pages(BuildContext context, Color paper) {
    final PageController? p = pc;
    if (p == null) return const SizedBox.shrink();
    final World? w = c.world;
    final bool none = widget.prefs.anim == PageAnim.none;
    final bool cover = widget.prefs.anim == PageAnim.cover;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails d) {
        if (c.selection != null) {
          _clearSelection();
          return;
        }
        final double x = d.localPosition.dx / (context.size?.width ?? 1);
        if (x < 1 / 3) {
          _turn(-1);
        } else if (x > 2 / 3) {
          _turn(1);
        } else {
          c.setToolbar(!c.toolbar);
        }
      },
      onLongPressStart: _longPress,
      onLongPressMoveUpdate: _longPressMove,
      onHorizontalDragEnd: none
          ? (DragEndDetails d) {
              if ((d.primaryVelocity ?? 0) < -100) _turn(1);
              if ((d.primaryVelocity ?? 0) > 100) _turn(-1);
            }
          : null,
      child: PageView.builder(
        key: ValueKey<int>(c.generation),
        controller: p,
        physics: none || c.selection != null
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemBuilder: (BuildContext context, int index) {
          final PageData? page = c.pageAt(index);
          if (page == null) return null;
          final bool current = index == c.currentIndex;
          final Widget body = ColoredBox(
            color: paper,
            child: PageBody(
              page: page,
              pager: c.pager!,
              layers: PageLayers(
                world: book.hasKnowledge
                    ? (current ? w : book.world(page.end))
                    : null,
                cutoff: page.end,
                notes: book.notes.live,
                selection: current ? c.selection : null,
                flash: current ? c.flash : null,
              ),
              onName: _openPerson,
            ),
          );
          if (!cover) return body;
          return AnimatedBuilder(
            animation: p,
            builder: (BuildContext context, Widget? child) {
              final double pos = p.hasClients && p.position.haveDimensions
                  ? p.page ?? index.toDouble()
                  : index.toDouble();
              final double delta = index - pos;
              // The next page stays still underneath; the current one slides away.
              if (delta > 0) {
                final double width = context.size?.width ?? 0;
                return Transform.translate(
                  offset: Offset(-delta * width, 0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: (0.16 * delta.clamp(0.0, 1.0)),
                          ),
                          blurRadius: 16,
                          spreadRadius: 2,
                          offset: const Offset(4, 0),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                );
              }
              return child!;
            },
            child: body,
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    final Tokens t = context.tk;
    final String chapter = c.page == null ? '' : book.chapters[c.chapter].title;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            chapter,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: t.ink3),
          ),
        ),
        if (book.knowledgeError != null)
          Tooltip(
            message: book.knowledgeError!,
            child: Icon(Icons.info_outline, color: t.amber, size: 16),
          ),
        if (c.beyondFrontier)
          Text(
            '人物整理到第 ${link.pageNo(book.status.frontier)} 页',
            style: TextStyle(fontSize: 11, color: t.ink3),
          ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final Tokens t = context.tk;
    final PageData? page = c.page;
    final Paginator? p = c.pager;
    if (page == null || p == null) return const SizedBox.shrink();
    final (int n, bool exactN) = p.globalPage(page.chapter, page.index);
    final (int total, bool exactT) = p.totalPages();
    final List<String> cast = c.pagePeople();
    final World? w = c.world;
    final List<(int, String)> notes = pageFootnotes(book, page.start, page.end);
    return Row(
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(
                text: '$n',
                style: TextStyle(color: t.ink2),
              ),
              TextSpan(
                text: ' / ${exactN && exactT ? '' : '约 '}$total',
                style: TextStyle(color: t.ink3),
              ),
            ],
          ),
          style: const TextStyle(
            fontSize: 12,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        if (notes.isNotEmpty)
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              _sheet(FootnotesPage(book: book, notes: notes));
            },
            child: Text('注释 ${notes.length}', style: TextStyle(color: t.ink2)),
          ),
        if (w != null && cast.isNotEmpty)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              _sheet(
                PeoplePage(link: link, onStartProcessing: _startProcessing),
              );
            },
            child: AnimatedOpacity(
              opacity: 1,
              duration: Motion.arrive,
              child: SizedBox(
                height: 24,
                width:
                    math.min(4, cast.length) * 16.0 +
                    8 +
                    (cast.length > 4 ? 26 : 0),
                child: Stack(
                  children: <Widget>[
                    for (int i = 0; i < math.min(4, cast.length); i++)
                      Positioned(
                        left: i * 16.0,
                        top: 1,
                        child: Avatar(
                          name: w.people[cast[i]]!['name'].toString(),
                          color: w.people[cast[i]]!['color']! as String,
                          isNew: c.isNewOnPage(cast[i]),
                        ),
                      ),
                    if (cast.length > 4)
                      Positioned(
                        right: 0,
                        top: 4,
                        child: Text(
                          '+${cast.length - 4}',
                          style: TextStyle(fontSize: 11, color: t.ink3),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _ribbon(BuildContext context) =>
      CustomPaint(size: const Size(14, 34), painter: _Ribbon(context.tk.qing));

  Widget _returnPill(BuildContext context) {
    final Tokens t = context.tk;
    final int back = c.returnTo!;
    return Material(
      color: t.ink,
      shape: const StadiumBorder(),
      elevation: 3,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            customBorder: const StadiumBorder(),
            onTap: () {
              c.returnTo = null;
              _jump(back, remember: false, highlight: (back, back));
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 9, 6, 9),
              child: Text(
                '↩ 回到第 ${link.pageNo(back)} 页',
                style: TextStyle(color: t.sheet, fontSize: 14),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.close,
              size: 16,
              color: t.sheet.withValues(alpha: 0.7),
            ),
            onPressed: c.clearReturn,
          ),
        ],
      ),
    );
  }

  Widget _selectionBar(BuildContext context, double top) {
    final Tokens t = context.tk;
    final (int s, int e) = c.selection!;
    final int len = (e - s).abs();
    final double y = (_pressAt?.dy ?? 100) + top;
    final bool above = y > top + 70;
    Widget action(String label, VoidCallback on) => InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        on();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(label, style: TextStyle(color: t.sheet, fontSize: 14)),
      ),
    );
    return Positioned(
      left: 16,
      right: 16,
      top: above ? math.max(top + 8, y - (_whoIsActive ? 120 : 64)) : y + 34,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Material(
              color: t.ink,
              shape: const StadiumBorder(),
              elevation: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  action('摘录', _excerpt),
                  action('批注', () {
                    _clearSelection();
                    _sheet(
                      MarginaliaPage(link: link, start: s, end: e),
                      full: true,
                    );
                  }),
                  action('笔记', () {
                    _clearSelection();
                    NoteEditor.open(
                      context,
                      book: book,
                      start: s,
                      end: e,
                      cutoff: c.cutoff,
                    );
                  }),
                  if (len <= 12)
                    action('这是谁', () => _identifyWho(s, e)),
                  action('问书', () {
                    final String quote = book.textBetween(s, e);
                    _clearSelection();
                    _openAsk(quote: quote);
                  }),
                  action('复制', () {
                    HapticFeedback.lightImpact();
                    Clipboard.setData(ClipboardData(text: book.textBetween(s, e)));
                    _clearSelection();
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('已复制')));
                  }),
                ],
              ),
            ),
            if (_whoIsActive) ...<Widget>[
              const SizedBox(height: 8),
              _whoIsCard(context, s, e),
            ],
          ],
        ),
      ),
    );
  }

  Widget _whoIsCard(BuildContext context, int s, int e) {
    final Tokens t = context.tk;
    return Material(
      color: t.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.rule.withValues(alpha: 0.8)),
      ),
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_whoIsLoading) ...<Widget>[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.zhu,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '正在判断…',
                style: TextStyle(fontSize: 13, color: t.ink2),
              ),
            ] else if (_whoIsResult != null && _whoIsResult!['ok'] == true) ...<Widget>[
              Text(
                '这里的「${_whoIsResult!['word'] ?? _whoIsWord}」指 ',
                style: TextStyle(fontSize: 13, color: t.ink2),
              ),
              Text(
                '${_whoIsResult!['name']}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.zhu,
                ),
              ),
              const SizedBox(width: 10),
              Pill(
                label: '打开人物卡',
                filled: true,
                dense: true,
                onTap: () {
                  final String personId = '${_whoIsResult!['id']}';
                  _clearSelection();
                  _openPerson(personId);
                },
              ),
            ] else ...<Widget>[
              Icon(Icons.help_outline, size: 16, color: t.ink3),
              const SizedBox(width: 6),
              Text(
                '这里看不出指的是谁',
                style: TextStyle(fontSize: 13, color: t.ink3),
              ),
              const SizedBox(width: 8),
              Pill(
                label: '问问这本书',
                dense: true,
                onTap: () {
                  final String quote = book.textBetween(s, e);
                  _clearSelection();
                  _openAsk(quote: quote);
                },
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 16, color: t.ink3),
              tooltip: '关闭',
              onPressed: () {
                setState(() => _whoIsActive = false);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final Tokens t = context.tk;
    final MediaQueryData mq = MediaQuery.of(context);
    final bool on = c.toolbar;
    final Paginator? p = c.pager;
    final bool ai = book.hasKnowledge;
    final bool marked = book.notes.bookmarkIn(c.start, c.cutoff) != null;
    final bool reduceMotion = mq.disableAnimations;
    final Duration duration = reduceMotion
        ? const Duration(milliseconds: 120)
        : Motion.toolbar;
    return IgnorePointer(
      ignoring: !on,
      child: AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: duration,
        curve: Curves.easeInOut,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AnimatedSlide(
                offset: on ? Offset.zero : const Offset(0, -1),
                duration: duration,
                curve: Curves.easeOutCubic,
                child: Material(
                  color: t.sheet,
                  elevation: 2,
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: Row(
                        children: <Widget>[
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () {
                              _clearSelection();
                              c.setToolbar(false);
                              Navigator.of(context).pop();
                            },
                            tooltip: '回书架',
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  widget.entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: t.ink,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  c.page == null
                                      ? ''
                                      : book.chapters[c.chapter].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: t.ink3),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '书签',
                            icon: Icon(
                              marked ? Icons.bookmark : Icons.bookmark_border,
                              color: marked ? t.qing : t.ink,
                            ),
                            onPressed: () => _changeNote(() {
                              HapticFeedback.lightImpact();
                              final Json? existing = book.notes.bookmarkIn(
                                c.start,
                                c.cutoff,
                              );
                              if (existing != null) {
                                book.notes.delete(existing);
                              } else {
                                book.notes.save(
                                  kind: 'bookmark',
                                  start: c.start,
                                  end: c.start,
                                  cutoff: c.cutoff,
                                );
                              }
                            }),
                          ),
                          IconButton(
                            tooltip: '搜索',
                            icon: const Icon(Icons.search),
                            onPressed: () =>
                                _sheet(SearchPage(link: link), full: true),
                          ),
                          PopupMenuButton<int>(
                            tooltip: '更多操作',
                            icon: const Icon(Icons.more_horiz),
                            onSelected: (int i) {
                              HapticFeedback.lightImpact();
                              switch (i) {
                                case 0:
                                  _openBookSheet();
                                case 1:
                                  Clipboard.setData(
                                    ClipboardData(text: notesMarkdown(book)),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('摘记已复制为 Markdown'),
                                    ),
                                  );
                                case 2:
                                  c.setToolbar(false);
                                  openTypography(context, widget.prefs);
                                case 3:
                                  if (c.page != null) {
                                    _sheet(
                                      MarginaliaPage(
                                        link: link,
                                        start: c.page!.start,
                                        end: c.page!.end,
                                        pageMode: true,
                                      ),
                                      full: true,
                                    );
                                  }
                              }
                            },
                            itemBuilder: (_) => const <PopupMenuEntry<int>>[
                              PopupMenuItem<int>(value: 0, child: Text('这本书')),
                              PopupMenuItem<int>(value: 1, child: Text('导出摘记')),
                              PopupMenuItem<int>(value: 2, child: Text('阅读设置')),
                              PopupMenuItem<int>(value: 3, child: Text('本页批注')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (p != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedSlide(
                  offset: on ? Offset.zero : const Offset(0, 1),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: Material(
                    color: t.sheet,
                    elevation: 8,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: mq.padding.bottom, top: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _progressRow(context, p),
                          _toolsRow(context, ai),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _progressRow(BuildContext context, Paginator p) {
    final Tokens t = context.tk;
    final (int total, _) = p.totalPages();
    final (int current, _) = p.globalPage(c.chapter, c.page?.index ?? 0);
    final int shown = (_drag ?? current).clamp(1, math.max(1, total));
    final int read = SeenStore.instance.maxRead(book.id, c.cutoff);
    String bubble() {
      final int offset = _offsetOfPage(shown, p);
      final Chapter ch = book.chapters[book.chapterAt(offset)];
      return '第 $shown 页 · ${safeTitle(ch, ch.o0 < read)}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: <Widget>[
          if (_drag != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: t.ink,
                borderRadius: BorderRadius.circular(16),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                bubble(),
                style: TextStyle(
                  color: t.sheet,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: c.chapter > 0
                    ? () {
                        HapticFeedback.lightImpact();
                        _jump(
                          book.chapters[c.chapter - 1].o0,
                          remember: false,
                        );
                      }
                    : null,
                child: const Text('上一章'),
              ),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _Ticks(<double>[
                          for (final Chapter ch in book.chapters)
                            ch.o0 / math.max(1, book.length),
                        ], t.ink3),
                      ),
                    ),
                    Slider(
                      min: 1,
                      max: math.max(2, total).toDouble(),
                      value: shown.toDouble().clamp(
                        1,
                        math.max(2, total).toDouble(),
                      ),
                      activeColor: t.ink,
                      inactiveColor: t.rule,
                      onChanged: (double v) {
                        final int next = v.round();
                        if (next != _drag) {
                          HapticFeedback.selectionClick();
                        }
                        setState(() => _drag = next);
                      },
                      onChangeEnd: (double v) {
                        HapticFeedback.lightImpact();
                        final int target = _offsetOfPage(v.round(), p);
                        setState(() => _drag = null);
                        _jump(target);
                      },
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: c.chapter + 1 < book.chapters.length
                    ? () {
                        HapticFeedback.lightImpact();
                        _jump(
                          book.chapters[c.chapter + 1].o0,
                          remember: false,
                        );
                      }
                    : null,
                child: const Text('下一章'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _offsetOfPage(int n, Paginator p) {
    for (int ci = book.chapters.length - 1; ci >= 0; ci--) {
      final (int first, _) = p.globalPage(ci, 0);
      if (first <= n) {
        if (!p.isReady(ci)) {
          final Chapter ch = book.chapters[ci];
          return math.min(
            ch.o1 - 1,
            ch.o0 + ((n - first) * p.charsPerPage()).round(),
          );
        }
        final List<PageData> pages = p.pages(ci);
        return pages[(n - first).clamp(0, pages.length - 1)].start;
      }
    }
    return 0;
  }

  Widget _toolsRow(BuildContext context, bool ai) {
    final Tokens t = context.tk;
    Widget tool(IconData icon, String label, bool isAi, VoidCallback on) =>
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              HapticFeedback.lightImpact();
              on();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: <Widget>[
                  Icon(
                    icon,
                    color: isAi ? (ai ? t.zhu : t.ink3) : t.ink,
                    size: 22,
                  ),
                  const SizedBox(height: 3),
                  Text(label, style: TextStyle(fontSize: 12, color: t.ink2)),
                ],
              ),
            ),
          ),
        );
    return Row(
      children: <Widget>[
        tool(
          Icons.format_list_bulleted,
          '目录',
          false,
          () => _sheet(TocPage(link: link), full: true),
        ),
        tool(
          Icons.people_outline,
          '人物',
          true,
          () => _sheet(
            PeoplePage(link: link, onStartProcessing: _startProcessing),
          ),
        ),
        tool(
          Icons.auto_stories_outlined,
          '前情',
          true,
          () => _sheet(RecapPage(link: link)),
        ),
        tool(Icons.chat_bubble_outline, '问书', true, () => _openAsk()),
        tool(Icons.text_fields, '排版', false, () {
          c.setToolbar(false);
          openTypography(context, widget.prefs);
        }),
      ],
    );
  }
}

class _Ribbon extends CustomPainter {
  _Ribbon(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width, s.height)
      ..lineTo(s.width / 2, s.height - 6)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Ribbon old) => old.color != color;
}

class _Ticks extends CustomPainter {
  _Ticks(this.marks, this.color);

  final List<double> marks;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    if (marks.length > 80) return;
    final Paint p = Paint()..color = color.withValues(alpha: 0.5);
    const double pad = 24;
    for (final double m in marks) {
      final double x = pad + m * (s.width - 2 * pad);
      canvas.drawRect(Rect.fromLTWH(x, s.height / 2 + 7, 1, 5), p);
    }
  }

  @override
  bool shouldRepaint(_Ticks old) => true;
}
