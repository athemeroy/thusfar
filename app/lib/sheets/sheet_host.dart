import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Opens the single reader drawer. Content pushed from inside it stays in the
/// same drawer (spec: 阅读页上最多一层抽屉).
Future<T?> openSheet<T>(
  BuildContext context,
  Widget root, {
  double initial = 0.45,
  bool full = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (BuildContext _) => DraggableScrollableSheet(
      initialChildSize: full ? 0.92 : initial,
      minChildSize: 0.2,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const <double>[0.45, 0.92],
      expand: false,
      builder: (BuildContext context, ScrollController scroll) =>
          SheetFrame(scroll: scroll, root: root),
    ),
  );
}

/// The drawer's own page stack: back pops a layer before closing the drawer.
class SheetFrame extends StatefulWidget {
  const SheetFrame({super.key, required this.scroll, required this.root});

  final ScrollController scroll;
  final Widget root;

  @override
  State<SheetFrame> createState() => SheetFrameState();
}

class SheetFrameState extends State<SheetFrame> {
  late final List<Widget> _stack = <Widget>[widget.root];
  bool _forward = true;

  void push(Widget page) => setState(() {
    _forward = true;
    _stack.add(page);
  });

  void pop() {
    if (_stack.length > 1) {
      setState(() {
        _forward = false;
        _stack.removeLast();
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Replaces the whole stack (e.g. jumping from the people list to a card).
  void reset(Widget page) => setState(() {
    _forward = true;
    _stack
      ..clear()
      ..add(page);
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
      child: Material(
        color: t.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SheetScope(
          state: this,
          scroll: widget.scroll,
          child: AnimatedSwitcher(
            duration: MediaQuery.of(context).disableAnimations
                ? const Duration(milliseconds: 120)
                : Motion.push,
            transitionBuilder: (Widget child, Animation<double> a) {
              final bool incoming = child.key == ValueKey<int>(_stack.length);
              final double from = (_forward == incoming) ? 1 : -1;
              return SlideTransition(
                position:
                    Tween<Offset>(
                      begin: Offset(from * 0.35, 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
                    ),
                child: FadeTransition(opacity: a, child: child),
              );
            },
            child: KeyedSubtree(
              key: ValueKey<int>(_stack.length),
              child: _stack.last,
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
    return Column(
      children: <Widget>[
        Expanded(
          child: CustomScrollView(
            controller: scope.scroll,
            slivers: <Widget>[
              SliverPersistentHeader(
                pinned: true,
                delegate: _Header(
                  height: 76 + headerExtraHeight,
                  builder: (BuildContext context) => Container(
                    color: t.sheet,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Center(
                          child: Container(
                            margin: const EdgeInsets.only(top: 8, bottom: 6),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: t.rule,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 50,
                          child: Row(
                            children: <Widget>[
                              if (back)
                                IconButton(
                                  icon: const Icon(Icons.arrow_back),
                                  color: t.ink,
                                  onPressed: scope.state.pop,
                                )
                              else
                                const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                              if (tag != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 20),
                                  child: Tag(tag!, color: t.zhu),
                                ),
                            ],
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
                child: bottom,
              ),
            ),
          ),
      ],
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
class Segmented extends StatelessWidget {
  const Segmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return Container(
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: AnimatedContainer(
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
        ],
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
