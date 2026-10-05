import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';

/// Opens the single reader drawer. Content pushed from inside it stays in the
/// same drawer (spec: 阅读页上最多一层抽屉).
Future<T?> openSheet<T>(
  BuildContext context,
  Widget root, {
  double initial = 0.45,
  bool full = false,
  Offset? anchorPoint,
}) {
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<T>(
      context: context,
      anchorPoint: anchorPoint,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (BuildContext _) => _ReaderDialog(root: root),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    anchorPoint: anchorPoint,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (BuildContext context) => AnimatedPadding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.toolbar,
      child: _ReaderDrawer(initial: full ? 0.92 : initial, root: root),
    ),
  );
}

class _ReaderDialog extends StatefulWidget {
  const _ReaderDialog({required this.root});
  final Widget root;

  @override
  State<_ReaderDialog> createState() => _ReaderDialogState();
}

class _ReaderDialogState extends State<_ReaderDialog> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final double height = math.max(
      100,
      math.min(
        820,
        media.size.height -
            media.viewInsets.vertical -
            media.padding.vertical -
            48,
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 600,
        height: height,
        child: SheetFrame(scroll: _scroll, root: widget.root, dialog: true),
      ),
    );
  }
}

class _ReaderDrawer extends StatefulWidget {
  const _ReaderDrawer({required this.root, required this.initial});

  final Widget root;
  final double initial;

  @override
  State<_ReaderDrawer> createState() => _ReaderDrawerState();
}

class _ReaderDrawerState extends State<_ReaderDrawer> {
  final DraggableScrollableController _extent = DraggableScrollableController();
  bool _keyboardVisible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (visible && !_keyboardVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _extent.isAttached) {
          _extent.animateTo(
            .92,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.push,
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
    _keyboardVisible = visible;
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    controller: _extent,
    initialChildSize: widget.initial,
    minChildSize: 0.2,
    maxChildSize: 0.92,
    snap: true,
    snapSizes: const <double>[0.45, 0.92],
    expand: false,
    builder: (BuildContext context, ScrollController scroll) =>
        MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: SheetFrame(scroll: scroll, root: widget.root, extent: _extent),
        ),
  );
}

/// The drawer's own page stack: back pops a layer before closing the drawer.
class SheetFrame extends StatefulWidget {
  const SheetFrame({
    super.key,
    required this.scroll,
    required this.root,
    this.extent,
    this.dialog = false,
  });

  final ScrollController scroll;
  final Widget root;
  final DraggableScrollableController? extent;
  final bool dialog;

  @override
  State<SheetFrame> createState() => SheetFrameState();
}

class _SheetEntry {
  _SheetEntry(this.page);
  final Widget page;
  final Key key = UniqueKey();
  final ScrollController inactiveScroll = ScrollController();
}

class SheetFrameState extends State<SheetFrame> {
  late final List<_SheetEntry> _stack = <_SheetEntry>[_SheetEntry(widget.root)];
  final FocusNode _focus = FocusNode(debugLabel: 'Reader drawer');

  void _restoreKeyboardFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  void _disposeEntry(_SheetEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => entry.inactiveScroll.dispose(),
    );
  }

  @override
  void dispose() {
    for (final _SheetEntry entry in _stack) {
      entry.inactiveScroll.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  bool _expandPending = false;

  /// A graph needs a readable viewport instead of inheriting a short list's
  /// collapsed drawer. Wait until the page transition has detached its old
  /// scroll position before animating the shared draggable controller.
  void expand() {
    if (widget.extent == null || _expandPending) return;
    _expandPending = true;
    void attempt(Duration _) {
      if (!mounted) return;
      final DraggableScrollableController extent = widget.extent!;
      if (!extent.isAttached || widget.scroll.positions.length != 1) {
        WidgetsBinding.instance.addPostFrameCallback(attempt);
        return;
      }
      _expandPending = false;
      widget.scroll.jumpTo(0);
      extent.animateTo(
        .92,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.push,
        curve: Curves.easeOutCubic,
      );
    }

    attempt(Duration.zero);
  }

  void push(Widget page) {
    HapticFeedback.lightImpact();
    setState(() {
      FocusManager.instance.primaryFocus?.unfocus();
      _stack.add(_SheetEntry(page));
    });
    _restoreKeyboardFocus();
  }

  void pop() {
    HapticFeedback.lightImpact();
    if (_stack.length > 1) {
      setState(() {
        FocusManager.instance.primaryFocus?.unfocus();
        _disposeEntry(_stack.removeLast());
      });
      _restoreKeyboardFocus();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Replaces the whole stack (e.g. jumping from the people list to a card).
  void reset(Widget page) => setState(() {
    for (final _SheetEntry entry in _stack) {
      _disposeEntry(entry);
    }
    _stack
      ..clear()
      ..add(_SheetEntry(page));
  });

  int get depth => _stack.length;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) pop();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): pop,
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          skipTraversal: true,
          child: Material(
            color: t.sheet,
            borderRadius: widget.dialog
                ? BorderRadius.circular(20)
                : const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            // Retain every route's State, text controllers, filters and scroll
            // position. Only the visible route uses the draggable controller;
            // hidden routes keep their own attached ScrollPosition.
            child: IndexedStack(
              index: _stack.length - 1,
              children: <Widget>[
                for (int i = 0; i < _stack.length; i++)
                  KeyedSubtree(
                    key: _stack[i].key,
                    child: ExcludeFocus(
                      excluding: i != _stack.length - 1,
                      child: TickerMode(
                        enabled: i == _stack.length - 1,
                        child: SheetScope(
                          state: this,
                          scroll: i == _stack.length - 1
                              ? widget.scroll
                              : _stack[i].inactiveScroll,
                          child: _stack[i].page,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SheetScope extends InheritedWidget {
  const SheetScope({
    super.key,
    required this.state,
    required this.scroll,
    required super.child,
  });

  final SheetFrameState state;
  final ScrollController scroll;

  static SheetScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SheetScope>()!;

  @override
  bool updateShouldNotify(SheetScope old) => true;
}

/// A drawer page: pinned header with the drag handle, then scrolling slivers.
class SheetPage extends StatelessWidget {
  const SheetPage({
    super.key,
    required this.title,
    this.titleWidget,
    this.tag,
    this.headerExtra,
    this.headerExtraHeight = 0,
    required this.slivers,
    this.bottom,
    this.path,
  });

  final String title;
  final Widget? titleWidget;
  final String? tag;
  final Widget? headerExtra;
  final double headerExtraHeight;
  final List<Widget> slivers;
  final Widget? bottom;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final SheetScope scope = SheetScope.of(context);
    final Tokens t = context.tk;
    final bool back = scope.state.depth > 1;
    final bool dialog = scope.state.widget.dialog;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double headingHeight = math.max(
      50,
      scaler.scale(17) * 1.5 + (path == null ? 0 : scaler.scale(11) * 1.3) + 8,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool stackedTag =
            tag != null && (box.maxWidth < 360 || scaler.scale(17) > 24);
        double tagHeight = 0;
        if (stackedTag) {
          final TextPainter painter = TextPainter(
            text: TextSpan(
              text: tag,
              style: DefaultTextStyle.of(
                context,
              ).style.copyWith(fontSize: 11, letterSpacing: .66),
            ),
            textDirection: Directionality.of(context),
            textScaler: scaler,
          )..layout(maxWidth: math.max(1, box.maxWidth - 56));
          tagHeight = painter.height + 12;
          painter.dispose();
        }
        final double headerHeight =
            headingHeight + (dialog ? 12 : 26) + tagHeight + headerExtraHeight;
        return Column(
          children: <Widget>[
            Expanded(
              child: CustomScrollView(
                controller: scope.scroll,
                slivers: <Widget>[
                  SliverPersistentHeader(
                    pinned: headerHeight < box.maxHeight * 0.65,
                    delegate: _Header(
                      height: headerHeight,
                      builder: (BuildContext context) => Container(
                        color: t.sheet,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (dialog)
                              const SizedBox(height: 12)
                            else
                              Center(
                                child: Container(
                                  margin: const EdgeInsets.only(
                                    top: 8,
                                    bottom: 6,
                                  ),
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: t.rule,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            SizedBox(
                              height: headingHeight,
                              child: Row(
                                children: <Widget>[
                                  if (back)
                                    IconButton(
                                      icon: const Icon(Icons.arrow_back),
                                      tooltip: '返回上一层',
                                      color: t.ink,
                                      onPressed: scope.state.pop,
                                    )
                                  else
                                    const SizedBox(width: 20),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        if (path != null)
                                          Text(
                                            path!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: t.ink3,
                                            ),
                                          ),
                                        titleWidget ??
                                            Text(
                                              title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 17,
                                                color: t.ink,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                      ],
                                    ),
                                  ),
                                  if (tag != null && !stackedTag)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Tag(tag!, color: t.zhu),
                                    ),
                                  IconButton(
                                    key: const ValueKey<String>(
                                      'reader-sheet-close',
                                    ),
                                    tooltip: '关闭阅读工具',
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                ],
                              ),
                            ),
                            if (stackedTag)
                              SizedBox(
                                height: tagHeight,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Tag(tag!, color: t.zhu),
                                  ),
                                ),
                              ),
                            if (headerExtra != null)
                              SizedBox(
                                height: headerExtraHeight,
                                child: headerExtra,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ...slivers,
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
            if (bottom != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: t.sheet,
                  border: Border(top: BorderSide(color: t.rule)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.max(1, box.maxHeight * .4),
                      ),
                      child: SingleChildScrollView(child: bottom),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Header extends SliverPersistentHeaderDelegate {
  _Header({required this.height, required this.builder});

  final double height;
  final WidgetBuilder builder;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => builder(context);

  @override
  bool shouldRebuild(_Header old) => true;
}

/// Segmented control used in drawer headers.
class Segmented extends StatefulWidget {
  const Segmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// Match the actual text wrap within each equally sized tab. A fixed header
  /// height clips three-character labels on narrow screens with large text.
  double heightForWidth(BuildContext context, double width) {
    final double cell = ((width - 46) / labels.length).clamp(
      1,
      double.infinity,
    );
    double height = 50;
    for (int i = 0; i < labels.length; i++) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: DefaultTextStyle.of(context).style.copyWith(
            fontSize: 13,
            fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: cell);
      final double measured = (math.max(44, painter.height + 14) + 6)
          .ceilToDouble();
      if (measured > height) height = measured;
      painter.dispose();
    }
    return height;
  }

  @override
  State<Segmented> createState() => _SegmentedState();
}

class _SegmentedState extends State<Segmented> {
  final List<FocusNode> _nodes = <FocusNode>[];
  List<String> get labels => widget.labels;
  int get index => widget.index;

  @override
  void initState() {
    super.initState();
    _resizeNodes();
  }

  void _resizeNodes() {
    while (_nodes.length > labels.length) {
      _nodes.removeLast().dispose();
    }
    while (_nodes.length < labels.length) {
      _nodes.add(FocusNode());
    }
  }

  @override
  void didUpdateWidget(covariant Segmented oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resizeNodes();
  }

  @override
  void dispose() {
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _choose(int next) {
    _nodes[next].requestFocus();
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _choose((index + 1) % labels.length),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _choose((index - 1 + labels.length) % labels.length),
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: t.paper,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < labels.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == index,
                  inMutuallyExclusiveGroup: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      focusNode: _nodes[i],
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _choose(i);
                      },
                      child: AnimatedContainer(
                        constraints: const BoxConstraints(minHeight: 44),
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i == index ? t.raised : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: i == index
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 4,
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 13,
                            color: i == index ? t.ink : t.ink2,
                            fontWeight: i == index
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
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
}

/// A section title inside a drawer.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: context.tk.ink3,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}
