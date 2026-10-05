import '../ui/reader_message.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
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
  final GlobalKey<CoverPageTurnState> _coverTurnKey =
      GlobalKey<CoverPageTurnState>();
  PageSpec? spec;
  int? _layoutAnchor;
  double _contentLeft = 0;
  double _contentWidth = 0;
  Rect _readingBounds = Rect.zero;
  Rect _toolsBounds = Rect.zero;
  bool _sheetOpen = false;
  Offset? _pressAt;
  (int, int)? _selectionSeed;
  Timer? _flashTimer;
  final FocusNode _focus = FocusNode();
  VoidCallback? _reopenAsk;
  Offset? _handleDragPointer;
  Offset? _handleDragSource;
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
    _wheelTimer?.cancel();
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
      letterSpacing: prefs.letterSpacing,
      fontFamily: prefs.fontFamily,
      fontFamilyFallback: prefs.fontFallback,
      color: _ink(t),
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (spec == next && c.pager != null) return;
    final bool first = c.pager == null;
    final int keep = first
        ? (widget.openAt ?? _initialOffset)
        : (_layoutAnchor ?? c.start);
    _layoutAnchor = keep;
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
    _layoutAnchor = offset;
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
        anchorPoint: anchorPoint ?? _toolsBounds.center,
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
      final Json res = await ask.whoIs(book.book, book.records, c.cutoff, s, e);
      if (!mounted) return;
      setState(() {
        _whoIsLoading = false;
        _whoIsResult = res;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _whoIsLoading = false;
        _whoIsResult = <String, Object?>{'ok': false, 'word': word};
      });
    }
  }

  void _openAsk({
    String? prefill,
    String? quote,
    int? selectedStart,
    int? selectedEnd,
    Offset? anchorPoint,
    bool restoreDraft = false,
  }) {
    _reopenAsk = () => _openAsk(
      prefill: prefill,
      quote: quote,
      selectedStart: selectedStart,
      selectedEnd: selectedEnd,
      anchorPoint: anchorPoint,
      restoreDraft: true,
    );
    _sheet(
      AskPage(
        link: link,
        prefill: prefill,
        quote: quote,
        selectedStart: selectedStart,
        selectedEnd: selectedEnd,
        restoreDraft: restoreDraft,
      ),
      full: true,
      anchorPoint: anchorPoint,
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
    if (widget.prefs.anim == PageAnim.cover) {
      if (c.pageAt(c.currentIndex + delta) == null) return;
      if (c.selection != null) c.select(null);
      _coverTurnKey.currentState?.turn(
        delta,
        animate: !MediaQuery.of(context).disableAnimations,
      );
      return;
    }
    final PageController? p = pc;
    if (p == null || !p.hasClients) return;
    if (c.pageAt(c.currentIndex + delta) == null) return;
    if (c.selection != null) c.select(null);
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
    if (index == c.currentIndex) return;
    final int before = c.chapter;
    c.onPage(index);
    _layoutAnchor = c.start;
    SeenStore.instance.maxRead(book.id, c.cutoff);
    if (c.chapter != before) HapticFeedback.lightImpact();
  }

  // ---------------------------------------------------------------- selection

  int? _hitOffset(Offset local) {
    final PageData? page = c.page;
    final Paginator? p = c.pager;
    if (page == null || p == null) return null;
    final double x = local.dx - _contentLeft;
    if (x < 0 || x >= _contentWidth) return null;
    double y = 0;
    for (final Frag f in page.frags) {
      final double h = f.lines * p.spec.line;
      if (local.dy >= y && local.dy < y + h && !f.image) {
        final Block b = book.blocks[f.block];
        final TextPainter tp = p.painterFor(b);
        final int shift = b.kind == 'h' ? 0 : indentShift;
        final int pos =
            tp.getPositionForOffset(Offset(x, f.top + (local.dy - y))).offset -
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
    _selectionSeed = c.selection;
  }

  void _longPressMove(LongPressMoveUpdateDetails d) {
    final int? at = _hitOffset(d.localPosition);
    final (int, int)? seed = _selectionSeed;
    if (at == null || seed == null || c.selection == null) return;
    HapticFeedback.selectionClick();
    if (_whoIsActive) {
      _whoIsActive = false;
      _whoIsResult = null;
      _whoIsLoading = false;
    }
    c.select(at < seed.$1 ? (at, seed.$2) : (seed.$1, at + 1), anchor: seed.$1);
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
              readerMessage(
                error is PyException ? error.message : null,
                fallback: '摘记未能保存，请检查剩余空间后重试。',
              ),
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
                          ? readerMessage(
                              error.message,
                              fallback: '撤销未能完成，请重新打开摘记后重试。',
                            )
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
              body: _readerPane(context, paper),
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
    LogicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyL,
  };
  static final Set<LogicalKeyboardKey> _previousKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.keyK,
    LogicalKeyboardKey.keyH,
  };
  bool _wheelLocked = false;
  Timer? _wheelTimer;

  /// A mouse wheel or trackpad scroll turns one page per gesture; the
  /// short pause stops one flick from skipping a whole chapter.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _sheetOpen ||
        c.toolbar ||
        _wheelLocked) {
      return;
    }
    if (!_readingBounds.contains(event.localPosition)) return;
    final double dy = event.scrollDelta.dy;
    if (dy.abs() < 4) return;
    _wheelLocked = true;
    _wheelTimer?.cancel();
    _wheelTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _wheelLocked = false;
    });
    _turn(dy > 0 ? 1 : -1);
  }

  Widget _readerPane(BuildContext context, Color paper) {
    return Listener(
      onPointerSignal: _wheel,
      child: _readerFocus(context, paper),
    );
  }

  /// Keep text and controls on usable displays when a hinge separates them.
  (Rect, Rect) _paneBounds(Size size, MediaQueryData media) {
    final Rect window = Offset.zero & size;
    for (final feature in media.displayFeatures) {
      final bool separates =
          feature.type == DisplayFeatureType.hinge ||
          (feature.type == DisplayFeatureType.fold &&
              feature.state == DisplayFeatureState.postureHalfOpened);
      if (!separates) continue;
      final Rect hinge = feature.bounds;
      if (hinge.height >= size.height * .85 &&
          hinge.width < size.width * .4 &&
          hinge.left > 0 &&
          hinge.right < size.width) {
        final Rect left = Rect.fromLTRB(0, 0, hinge.left, size.height);
        final Rect right = Rect.fromLTRB(
          hinge.right,
          0,
          size.width,
          size.height,
        );
        final Rect reading = left.width >= 180 ? left : right;
        final Rect tools = right.width >= 180 && reading == left
            ? right
            : reading;
        return (reading, tools);
      }
      if (hinge.width >= size.width * .85 &&
          hinge.height < size.height * .4 &&
          hinge.top > 0 &&
          hinge.bottom < size.height) {
        final Rect upper = Rect.fromLTRB(0, 0, size.width, hinge.top);
        final Rect lower = Rect.fromLTRB(
          0,
          hinge.bottom,
          size.width,
          size.height,
        );
        final Rect reading = upper.height >= 160 ? upper : lower;
        final Rect tools = lower.height >= 160 && reading == upper
            ? lower
            : reading;
        return (reading, tools);
      }
    }
    return (window, window);
  }

  Widget _readerFocus(BuildContext context, Color paper) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (FocusNode _, KeyEvent e) {
        if (_sheetOpen || e is KeyUpEvent) return KeyEventResult.ignored;
        final HardwareKeyboard keyboard = HardwareKeyboard.instance;
        if (keyboard.isControlPressed ||
            keyboard.isMetaPressed ||
            keyboard.isAltPressed) {
          return KeyEventResult.ignored;
        }
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
        // Computers: arrows, space, Vim keys (j/k/h/l) and page keys turn pages.
        if (e.logicalKey == LogicalKeyboardKey.space &&
            keyboard.isShiftPressed) {
          _turn(-1);
          return KeyEventResult.handled;
        }
        if (_nextKeys.contains(e.logicalKey)) {
          _turn(1);
          return KeyEventResult.handled;
        }
        if (_previousKeys.contains(e.logicalKey)) {
          _turn(-1);
          return KeyEventResult.handled;
        }
        // Desktop keyboard reading actions.
        if (e.logicalKey == LogicalKeyboardKey.keyB) {
          _toggleBookmark();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.keyT) {
          _sheet(TocPage(link: link), full: true);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.keyN) {
          _sheet(TocPage(link: link, tab: 2), full: true);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.keyR) {
          _sheet(RecapPage(link: link, onOpenProcessing: _startProcessing));
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.slash) {
          _sheet(SearchPage(link: link), full: true);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.keyP) {
          _sheet(PeoplePage(link: link, onStartProcessing: _startProcessing));
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.keyA) {
          _openAsk();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.equal ||
            e.logicalKey == LogicalKeyboardKey.add) {
          HapticFeedback.selectionClick();
          widget.prefs.update(
            (Prefs p) => p.fontSize = (p.fontSize + 1).clamp(14, 32),
          );
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.minus) {
          HapticFeedback.selectionClick();
          widget.prefs.update(
            (Prefs p) => p.fontSize = (p.fontSize - 1).clamp(14, 32),
          );
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
          final (Rect reading, Rect tools) = _paneBounds(
            box.biggest,
            MediaQuery.of(context),
          );
          _readingBounds = reading;
          _toolsBounds = tools;
          final double verticalMargin = widget.prefs.pageVerticalMargin;
          final double safeTop = reading.top == 0 ? pagePadding.top : 0;
          final double safeBottom = reading.bottom == box.maxHeight
              ? pagePadding.bottom
              : 0;
          final double top = reading.top + safeTop + 32 + verticalMargin;
          final double bottom = safeBottom + 40 + verticalMargin;
          final double columnWidth = math.min(600, reading.width);
          final double outerInset = (reading.width - columnWidth) / 2;
          final double maxInset = math.max(0, (columnWidth - 1) / 2);
          final double leftInset = math.min(
            maxInset,
            (reading.left == 0 ? pagePadding.left : 0) +
                widget.prefs.pageHorizontalMargin,
          );
          final double rightInset = math.min(
            math.max(0, columnWidth - leftInset - 1),
            (reading.right == box.maxWidth ? pagePadding.right : 0) +
                widget.prefs.pageHorizontalMargin,
          );
          final double availableWidth = math.max(
            1,
            columnWidth - leftInset - rightInset,
          );
          final double pageWidth = math.max(1, math.min(560, availableWidth));
          final double centering = (availableWidth - pageWidth) / 2;
          final double pageLeft = outerInset + leftInset + centering;
          final double pageRight = outerInset + rightInset + centering;
          _contentLeft = pageLeft;
          _contentWidth = pageWidth;
          final Size area = Size(
            pageWidth,
            math.max(1, reading.bottom - top - bottom),
          );
          _ensureLayout(area, context.tk);
          // Controls animate over the page without changing its geometry.
          return Stack(
            children: <Widget>[
              Positioned(
                left: reading.left,
                width: reading.width,
                top: top,
                height: area.height,
                child: SizedBox(
                  key: const ValueKey<String>('reader-page-viewport'),
                  child: _pages(
                    context,
                    paper,
                    viewportWidth: reading.width,
                    contentInsets: EdgeInsets.only(
                      left: pageLeft,
                      right: pageRight,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: reading.left + pageLeft,
                width: pageWidth,
                top: reading.top + safeTop + 10,
                height: 28,
                child: _header(context),
              ),
              Positioned(
                left: reading.left + pageLeft,
                width: pageWidth,
                bottom: box.maxHeight - reading.bottom + safeBottom + 6,
                height: 44,
                child: _footer(context),
              ),
              if (book.notes.bookmarkIn(c.start, c.cutoff) != null)
                Positioned(
                  left: reading.left + pageLeft + pageWidth - 16,
                  top: reading.top,
                  child: _ribbon(context),
                ),
              if (c.returnTo != null)
                Positioned(
                  left: reading.left + pageLeft,
                  width: pageWidth,
                  bottom: box.maxHeight - reading.bottom + safeBottom + 48,
                  child: Center(child: _returnPill(context)),
                ),
              if (c.selection != null) ...<Widget>[
                _selectionHandle(context, top, start: true),
                _selectionHandle(context, top, start: false),
                _selectionBar(context, top),
              ],
              if (tools != reading && !c.toolbar)
                Positioned.fromRect(
                  rect: tools,
                  child: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                widget.entry.title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.tk.ink,
                                  fontSize: 20,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 12,
                                children: <Widget>[
                                  TextButton.icon(
                                    onPressed:
                                        c.pageAt(c.currentIndex - 1) == null
                                        ? null
                                        : () => _turn(-1),
                                    icon: const Icon(Icons.chevron_left),
                                    label: const Text('上一页'),
                                  ),
                                  TextButton.icon(
                                    onPressed:
                                        c.pageAt(c.currentIndex + 1) == null
                                        ? null
                                        : () => _turn(1),
                                    icon: const Icon(Icons.chevron_right),
                                    label: const Text('下一页'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () => c.setToolbar(true),
                                icon: const Icon(Icons.menu_book_outlined),
                                label: const Text('阅读工具'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: tools.left,
                width: tools.width,
                top: tools.top,
                height: tools.height,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(size: tools.size, displayFeatures: const []),
                  child: _toolbar(context),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pages(
    BuildContext context,
    Color paper, {
    required double viewportWidth,
    required EdgeInsets contentInsets,
  }) {
    final PageController? p = pc;
    if (p == null) return const SizedBox.shrink();
    final World? w = c.world;
    final bool none = widget.prefs.anim == PageAnim.none;
    final bool cover = widget.prefs.anim == PageAnim.cover;
    Widget? pageBody(int index) {
      final PageData? page = c.pageAt(index);
      if (page == null) return null;
      final bool current = index == c.currentIndex;
      return ColoredBox(
        color: paper,
        child: Padding(
          padding: contentInsets,
          child: Align(
            alignment: Alignment.topCenter,
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
          ),
        ),
      );
    }

    return Semantics(
      key: const ValueKey<String>('reader-page-actions'),
      container: true,
      explicitChildNodes: true,
      label: '阅读正文',
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (c.pageAt(c.currentIndex - 1) != null)
          const CustomSemanticsAction(label: '上一页'): () => _turn(-1),
        if (c.pageAt(c.currentIndex + 1) != null)
          const CustomSemanticsAction(label: '下一页'): () => _turn(1),
        const CustomSemanticsAction(label: '阅读工具'): () => c.setToolbar(true),
      },
      child: GestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails d) {
          if (c.selection != null) {
            _clearSelection();
            return;
          }
          final double x = d.localPosition.dx / math.max(1, viewportWidth);
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
        child: cover
            ? CoverPageTurn(
                key: _coverTurnKey,
                currentIndex: c.currentIndex,
                generation: c.generation,
                canShow: (int index) => c.pageAt(index) != null,
                pageBuilder: (BuildContext _, int index) => pageBody(index)!,
                onPageChanged: _onPageChanged,
                swipingEnabled: c.selection == null,
              )
            : PageView.builder(
                key: ValueKey<int>(c.generation),
                controller: p,
                physics: none || c.selection != null
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _onPageChanged,
                itemBuilder: (BuildContext context, int index) =>
                    pageBody(index),
              ),
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
            style: TextStyle(
              fontSize: 11,
              color: t.ink3,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
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
          Tooltip(
            message: '本页人物 (${cast.length})',
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(44, 44),
              ),
              onPressed: () {
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
                            style: TextStyle(
                              fontSize: 11,
                              color: t.ink3,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _toggleBookmark() => _changeNote(() {
    HapticFeedback.lightImpact();
    final Json? existing = book.notes.bookmarkIn(c.start, c.cutoff);
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
  });

  Widget _ribbon(BuildContext context) => Tooltip(
    message: '已加书签',
    child: GestureDetector(
      onTap: _toggleBookmark,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: -34, end: 0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        builder: (BuildContext context, double value, Widget? child) =>
            Transform.translate(offset: Offset(0, value), child: child),
        child: CustomPaint(
          size: const Size(14, 34),
          painter: _Ribbon(context.tk.qing),
        ),
      ),
    ),
  );

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
              HapticFeedback.lightImpact();
              final bool reopen = c.returnToAsk;
              c.returnTo = null;
              c.returnToAsk = false;
              _jump(back, remember: false, highlight: (back, back));
              final int generation = c.generation;
              if (reopen) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted &&
                      c.generation == generation &&
                      c.returnTo == null) {
                    _reopenAsk?.call();
                  }
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 9, 6, 9),
              child: Text(
                '↩ 回到第 ${link.pageNo(back)} 页',
                style: TextStyle(
                  color: t.sheet,
                  fontSize: 14,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭返回提示',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.close,
              size: 16,
              color: t.sheet.withValues(alpha: 0.7),
            ),
            onPressed: () {
              HapticFeedback.lightImpact();
              c.clearReturn();
            },
          ),
        ],
      ),
    );
  }

  /// Handles use the same source painter as the visible page, so either end
  /// can be corrected independently without rebuilding a quote from text.
  Widget _selectionHandle(
    BuildContext context,
    double top, {
    required bool start,
  }) {
    final (int a, int z) = c.selection!;
    final Paginator pager = c.pager!;
    final int offset = start ? a : z;
    double y = 0;
    Offset? caret;
    Offset? sourcePoint;
    for (final Frag fragment in c.page!.frags) {
      final Block block = book.blocks[fragment.block];
      final int local = offset - block.o;
      if (!fragment.image &&
          (start
              ? local >= fragment.start && local < fragment.end
              : local > fragment.start && local <= fragment.end)) {
        final TextPainter painter = pager.painterFor(block);
        final int shift = block.kind == 'h' ? 0 : indentShift;
        caret =
            painter.getOffsetForCaret(
              TextPosition(
                offset: local + shift,
                affinity: start
                    ? TextAffinity.downstream
                    : TextAffinity.upstream,
              ),
              Rect.zero,
            ) +
            Offset(_readingBounds.left + _contentLeft, top + y - fragment.top);
        sourcePoint =
            painter.getOffsetForCaret(
              TextPosition(offset: local + shift - (start ? 0 : 1)),
              Rect.zero,
            ) +
            Offset(_contentLeft, y - fragment.top + pager.spec.line / 2);
        painter.dispose();
        break;
      }
      y += fragment.lines * pager.spec.line;
    }
    if (caret == null) return const SizedBox.shrink();
    final double line = pager.spec.line;
    return Positioned(
      left: (caret.dx - 22).clamp(
        _readingBounds.left,
        _readingBounds.right - 44,
      ),
      top: caret.dy + line - 12,
      width: 44,
      height: 44,
      child: Semantics(
        label: start ? '调整选文起点' : '调整选文终点',
        child: GestureDetector(
          key: ValueKey<String>(
            start ? 'reader-selection-start' : 'reader-selection-end',
          ),
          behavior: HitTestBehavior.opaque,
          onPanStart: (DragStartDetails details) {
            _handleDragPointer = details.globalPosition;
            _handleDragSource = sourcePoint;
            HapticFeedback.selectionClick();
          },
          onPanUpdate: (DragUpdateDetails details) {
            if (c.selection == null ||
                _handleDragPointer == null ||
                _handleDragSource == null) {
              return;
            }
            final Offset local =
                _handleDragSource! +
                details.globalPosition -
                _handleDragPointer!;
            final int? at = _hitOffset(local);
            if (at == null) return;
            final (int s, int e) = c.selection!;
            c.select(
              start ? (math.min(at, e - 1), e) : (s, math.max(s + 1, at + 1)),
            );
          },
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 14,
              height: 22,
              decoration: BoxDecoration(
                color: context.tk.qing,
                borderRadius: BorderRadius.circular(7),
              ),
            ),
          ),
        ),
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
      left: _readingBounds.left + 16,
      width: math.max(1, _readingBounds.width - 32),
      top: above ? math.max(top + 8, y - (_whoIsActive ? 120 : 64)) : y + 34,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Material(
              color: t.ink,
              shape: const StadiumBorder(),
              elevation: 4,
              child: Wrap(
                alignment: WrapAlignment.center,
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
                  if (len <= 12) action('这是谁', () => _identifyWho(s, e)),
                  action('问书', () {
                    final String quote = book.textBetween(s, e);
                    _clearSelection();
                    _openAsk(quote: quote, selectedStart: s, selectedEnd: e);
                  }),
                  action('复制', () {
                    HapticFeedback.lightImpact();
                    Clipboard.setData(
                      ClipboardData(text: book.textBetween(s, e)),
                    );
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
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (_whoIsLoading) ...<Widget>[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.zhu),
              ),
              const SizedBox(width: 10),
              Text('正在判断…', style: TextStyle(fontSize: 13, color: t.ink2)),
            ] else if (_whoIsResult != null &&
                _whoIsResult!['ok'] == true) ...<Widget>[
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
              Text('这里看不出指的是谁', style: TextStyle(fontSize: 13, color: t.ink3)),
              const SizedBox(width: 8),
              Pill(
                label: '问问这本书',
                dense: true,
                onTap: () {
                  final String quote = book.textBetween(s, e);
                  _clearSelection();
                  _openAsk(quote: quote, selectedStart: s, selectedEnd: e);
                },
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 16, color: t.ink3),
              tooltip: '关闭',
              onPressed: () {
                HapticFeedback.selectionClick();
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
    final Duration duration = reduceMotion ? Duration.zero : Motion.toolbar;
    return ExcludeSemantics(
      excluding: !on,
      child: IgnorePointer(
        ignoring: !on,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0,
          duration: duration,
          curve: Curves.easeInOut,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: KeyedSubtree(
              key: const ValueKey<String>('reader-toolbar-panel'),
              child: Material(
                color: t.sheet,
                child: Padding(
                  padding: EdgeInsets.only(bottom: mq.padding.bottom, top: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _toolbarActions(context, marked),
                      if (p != null) ...<Widget>[
                        _progressRow(context, p),
                        _toolsRow(context, ai),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbarActions(BuildContext context, bool marked) {
    final Tokens t = context.tk;
    return SizedBox(
      height: math.max(
        52,
        MediaQuery.textScalerOf(context).scale(15) * 2.2 + 14,
      ),
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
                  c.page == null ? '' : book.chapters[c.chapter].title,
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
            onPressed: _toggleBookmark,
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => _sheet(SearchPage(link: link), full: true),
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
                  Clipboard.setData(ClipboardData(text: notesMarkdown(book)));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('摘记已复制')));
                case 2:
                  c.setToolbar(false);
                  openTypography(
                    context,
                    widget.prefs,
                    anchorPoint: _toolsBounds.center,
                  );
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
      return '第 $shown 页 · ${safeTitle(ch, ch.o0 < read, checkPending: book.status.titleCheckPending)}';
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
                        _jump(book.chapters[c.chapter - 1].o0, remember: false);
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
                        _jump(book.chapters[c.chapter + 1].o0, remember: false);
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
          child: Tooltip(
            message: label,
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
          () =>
              _sheet(RecapPage(link: link, onOpenProcessing: _startProcessing)),
        ),
        tool(Icons.chat_bubble_outline, '问书', true, () => _openAsk()),
        tool(Icons.text_fields, '排版', false, () {
          c.setToolbar(false);
          openTypography(
            context,
            widget.prefs,
            anchorPoint: _toolsBounds.center,
          );
        }),
      ],
    );
  }
}

/// A cover turn keeps the destination fixed below the page being moved.
/// The reading position changes only after the outgoing page has left view.
class CoverPageTurn extends StatefulWidget {
  const CoverPageTurn({
    super.key,
    required this.currentIndex,
    required this.generation,
    required this.canShow,
    required this.pageBuilder,
    required this.onPageChanged,
    this.swipingEnabled = true,
  });

  final int currentIndex;
  final int generation;
  final bool Function(int index) canShow;
  final Widget Function(BuildContext context, int index) pageBuilder;
  final ValueChanged<int> onPageChanged;
  final bool swipingEnabled;

  @override
  State<CoverPageTurn> createState() => CoverPageTurnState();
}

class CoverPageTurnState extends State<CoverPageTurn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: Motion.page,
  );
  int? _target;
  int? _direction;
  bool _dragging = false;
  int _epoch = 0;
  double _viewportWidth = 1;

  @override
  void didUpdateWidget(CoverPageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation ||
        oldWidget.currentIndex != widget.currentIndex) {
      _reset();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _progress.dispose();
    super.dispose();
  }

  void _reset() {
    _epoch++;
    _progress.stop();
    _target = null;
    _direction = null;
    _dragging = false;
  }

  bool _begin(int direction) {
    if (_target != null || direction == 0) return false;
    final int target = widget.currentIndex + direction;
    if (!widget.canShow(target)) return false;
    setState(() {
      _target = target;
      _direction = direction;
      _progress.value = 0;
    });
    return true;
  }

  /// Used by tap, volume, and keyboard turns. A turn in flight is not restarted.
  void turn(int delta, {bool animate = true}) {
    if (delta == 0 || _target != null || _dragging) return;
    final int direction = delta.sign;
    final int target = widget.currentIndex + direction;
    if (!widget.canShow(target)) return;
    if (!animate) {
      widget.onPageChanged(target);
      return;
    }
    if (_begin(direction)) unawaited(_settle(true));
  }

  Future<void> _settle(bool complete) async {
    final int? target = _target;
    if (target == null) return;
    final int epoch = ++_epoch;
    final double end = complete ? 1 : 0;
    final int milliseconds = math.max(
      80,
      (Motion.page.inMilliseconds * (end - _progress.value).abs()).round(),
    );
    try {
      await _progress
          .animateTo(
            end,
            duration: Duration(milliseconds: milliseconds),
            curve: Motion.pageCurve,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || epoch != _epoch) return;
    if (complete) widget.onPageChanged(target);
    setState(() {
      _target = null;
      _direction = null;
      _dragging = false;
      _progress.value = 0;
    });
  }

  void _onDragStart(DragStartDetails details) {
    if (_target != null) return;
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final double movement = details.primaryDelta ?? 0;
    if (movement == 0) return;
    if (_target == null && !_begin(movement < 0 ? 1 : -1)) return;
    _progress.value =
        (_progress.value - _direction! * movement / _viewportWidth).clamp(
          0.0,
          1.0,
        );
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    if (_target == null) return;
    final double towardTarget = -_direction! * (details.primaryVelocity ?? 0);
    final bool complete =
        towardTarget > 450 || (towardTarget >= -450 && _progress.value >= 0.5);
    unawaited(_settle(complete));
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    if (_target != null) unawaited(_settle(false));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportWidth = math.max(1, constraints.maxWidth);
        final Widget current = RepaintBoundary(
          key: const ValueKey<String>('cover-current-page'),
          child: widget.pageBuilder(context, widget.currentIndex),
        );
        final int? target = _target;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.swipingEnabled ? _onDragStart : null,
          onHorizontalDragUpdate: widget.swipingEnabled ? _onDragUpdate : null,
          onHorizontalDragEnd: widget.swipingEnabled ? _onDragEnd : null,
          onHorizontalDragCancel: widget.swipingEnabled ? _onDragCancel : null,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (target != null)
                  ExcludeSemantics(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        key: const ValueKey<String>('cover-target-page'),
                        child: widget.pageBuilder(context, target),
                      ),
                    ),
                  ),
                AnimatedBuilder(
                  animation: _progress,
                  child: IgnorePointer(
                    ignoring: target != null,
                    child: current,
                  ),
                  builder: (BuildContext context, Widget? child) {
                    final int direction = _direction ?? 0;
                    final double distance =
                        -direction * _progress.value * _viewportWidth;
                    return Transform.translate(
                      offset: Offset(distance, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: direction == 0
                              ? null
                              : <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.16 * _progress.value,
                                    ),
                                    blurRadius: 16,
                                    spreadRadius: 2,
                                    offset: Offset(direction * 4.0, 0),
                                  ),
                                ],
                        ),
                        child: child,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
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
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.25), 3, false);
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
