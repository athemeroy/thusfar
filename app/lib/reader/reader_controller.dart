import 'package:flutter/foundation.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../data/library.dart';
import 'paginator.dart';

/// Where the reader is, what they know there, and how to get back.
class ReaderController extends ChangeNotifier {
  ReaderController({required this.library, required this.book}) {
    book.addListener(touch);
  }

  @override
  void dispose() {
    book.removeListener(touch);
    super.dispose();
  }

  final Library library;
  final BookData book;
  Paginator? pager;

  /// Anchor for the virtual page index; see [pageAt].
  static const int base = 1 << 20;
  int _anchorChapter = 0;
  int _anchorPage = 0;
  int _anchorIndex = base;
  int currentIndex = base;
  PageData? page;

  /// Offset to return to after a jump (「↩ 回到第 9 页」).
  int? returnTo;
  (int, int)? selection;
  (int, int)? flash;
  bool toolbar = false;
  int _generation = 0;
  int get generation => _generation;

  int get cutoff => page?.end ?? 0;
  int get start => page?.start ?? 0;
  int get chapter => page?.chapter ?? 0;

  World? get world => book.hasKnowledge ? book.world(cutoff) : null;

  /// Sets up pagination, keeping the character at [offset] on screen.
  void layout(Paginator p, int offset) {
    pager = p;
    final int c = book.chapterAt(offset);
    _anchorChapter = c;
    _anchorPage = p.pageOf(c, offset);
    _generation++;
    _anchorIndex = base;
    currentIndex = base;
    page = p.pages(c)[_anchorPage];
  }

  /// The page at virtual index [index], walking chapters from the anchor.
  PageData? pageAt(int index) {
    final Paginator? p = pager;
    if (p == null) return null;
    int c = _anchorChapter;
    int i = _anchorPage + (index - _anchorIndex);
    while (i < 0) {
      if (c == 0) return null;
      c--;
      i += p.pages(c).length;
    }
    while (i >= p.pages(c).length) {
      i -= p.pages(c).length;
      if (c + 1 >= book.chapters.length) return null;
      c++;
    }
    return p.pages(c)[i];
  }

  void onPage(int index) {
    final PageData? next = pageAt(index);
    if (next == null) return;
    currentIndex = index;
    page = next;
    selection = null;
    toolbar = false;
    library.saveProgress(book.id, next.start, next.end, book.length);
    notifyListeners();
  }

  /// Rebases the virtual index on [offset]; returns the new index to show.
  int jump(int offset, {bool remember = true, (int, int)? highlight}) {
    final Paginator p = pager!;
    if (remember && returnTo == null) returnTo = start;
    final int c = book.chapterAt(offset);
    _anchorChapter = c;
    _anchorPage = p.pageOf(c, offset);
    _generation++;
    _anchorIndex = base;
    currentIndex = base;
    page = p.pages(c)[_anchorPage];
    flash = highlight;
    selection = null;
    library.saveProgress(book.id, page!.start, page!.end, book.length);
    notifyListeners();
    return base;
  }

  void clearReturn() {
    returnTo = null;
    notifyListeners();
  }

  void setToolbar(bool on) {
    toolbar = on;
    notifyListeners();
  }

  /// Source selections stay on this page and in the textual block where the
  /// gesture began. Off-page word expansion and cross-block drags are clipped.
  void select((int, int)? range, {int? anchor}) {
    selection = null;
    if (range != null && page != null && start < cutoff) {
      final int point = (anchor ?? range.$1).clamp(start, cutoff - 1);
      final Block block = book.blocks[book.blockAt(point)];
      if (block.kind == 'p' || block.kind == 'h') {
        final int low = start > block.o ? start : block.o;
        final int blockEnd = block.o + block.text.length;
        final int high = cutoff < blockEnd ? cutoff : blockEnd;
        if (low < high) {
          int a = range.$1.clamp(low, high);
          int z = range.$2.clamp(low, high);
          bool splitsPair(int at) =>
              at > block.o &&
              at < blockEnd &&
              block.text.codeUnitAt(at - block.o - 1) >= 0xd800 &&
              block.text.codeUnitAt(at - block.o - 1) <= 0xdbff &&
              block.text.codeUnitAt(at - block.o) >= 0xdc00 &&
              block.text.codeUnitAt(at - block.o) <= 0xdfff;
          // Include the full visible character when a drag lands inside an
          // emoji; clip inward if the page itself ends inside that character.
          if (splitsPair(a)) a += a > low ? -1 : 1;
          if (splitsPair(z)) z += z < high ? 1 : -1;
          if (a < z) selection = (a, z);
        }
      }
    }
    notifyListeners();
  }

  void clearFlash() {
    if (flash == null) return;
    flash = null;
    notifyListeners();
  }

  void touch() => notifyListeners();

  /// People on the current page in reading order, canonical ids.
  List<String> pagePeople() {
    final World? w = world;
    final PageData? pg = page;
    if (w == null || pg == null) return const <String>[];
    final List<String> ids = <String>[];
    for (final Mention m in book.mentions(pg.chapter)) {
      if (m.start < pg.start || m.start >= pg.end) continue;
      final String id = w.canon(m.id);
      if (w.people.containsKey(id) && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// People in the current chapter up to the cutoff.
  List<String> chapterPeople() {
    final World? w = world;
    final PageData? pg = page;
    if (w == null || pg == null) return const <String>[];
    final Map<String, int> count = <String, int>{};
    for (final Mention m in book.mentions(pg.chapter)) {
      if (m.start >= pg.end) continue;
      final String id = w.canon(m.id);
      if (w.people.containsKey(id)) count[id] = (count[id] ?? 0) + 1;
    }
    final List<String> ids = count.keys.toList()
      ..sort((String a, String b) => count[b]!.compareTo(count[a]!));
    return ids;
  }

  bool isNewOnPage(String id) {
    final World? w = world;
    final PageData? pg = page;
    if (w == null || pg == null) return false;
    final Person? p = w.person(id);
    return p != null && p.first >= pg.start && p.first < pg.end;
  }

  /// 「人物整理到第 34 页」 applies when processing has not reached this page.
  bool get beyondFrontier {
    final ProcessStatus s = book.status;
    return (s.isRunning || s.isPaused || s.isError) &&
        cutoff > s.frontier &&
        book.chapters[chapter].kind == 'body';
  }
}
