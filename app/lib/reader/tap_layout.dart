/// A tap affects only the active reading pane, including its page margins.
/// Swipes, keyboard shortcuts and volume keys keep their own directions.
enum ReaderTapAction { previous, tools, next, none }

enum ReaderTapPreset { classic, leftHanded, rightHanded }

/// Nine row-major regions. The centre always opens tools so a custom layout
/// cannot leave a touch-only reader without a way back to settings.
class ReaderTapLayout {
  ReaderTapLayout._(List<ReaderTapAction> actions)
    : actions = List<ReaderTapAction>.unmodifiable(actions);

  factory ReaderTapLayout.preset(ReaderTapPreset preset) {
    const ReaderTapAction p = ReaderTapAction.previous;
    const ReaderTapAction t = ReaderTapAction.tools;
    const ReaderTapAction n = ReaderTapAction.next;
    return ReaderTapLayout._(switch (preset) {
      ReaderTapPreset.classic => <ReaderTapAction>[p, t, n, p, t, n, p, t, n],
      ReaderTapPreset.leftHanded => <ReaderTapAction>[
        p,
        t,
        p,
        n,
        t,
        p,
        n,
        t,
        n,
      ],
      ReaderTapPreset.rightHanded => <ReaderTapAction>[
        p,
        t,
        p,
        p,
        t,
        n,
        n,
        t,
        n,
      ],
    });
  }

  /// Invalid or future settings safely restore the original tap behaviour.
  factory ReaderTapLayout.fromJson(Object? value) {
    if (value is! List || value.length != 9) {
      return ReaderTapLayout.preset(ReaderTapPreset.classic);
    }
    final List<ReaderTapAction> actions = <ReaderTapAction>[];
    for (final Object? name in value) {
      final ReaderTapAction? action = switch (name) {
        'previous' => ReaderTapAction.previous,
        'tools' => ReaderTapAction.tools,
        'next' => ReaderTapAction.next,
        'none' => ReaderTapAction.none,
        _ => null,
      };
      if (action == null) {
        return ReaderTapLayout.preset(ReaderTapPreset.classic);
      }
      actions.add(action);
    }
    actions[4] = ReaderTapAction.tools;
    return ReaderTapLayout._(actions);
  }

  final List<ReaderTapAction> actions;

  List<String> toJson() => actions.map((action) => action.name).toList();

  ReaderTapLayout withAction(int index, ReaderTapAction action) {
    RangeError.checkValidIndex(index, actions);
    if (index == 4 || actions[index] == action) return this;
    final List<ReaderTapAction> next = List<ReaderTapAction>.of(actions);
    next[index] = action;
    return ReaderTapLayout._(next);
  }

  ReaderTapPreset? get matchingPreset {
    for (final ReaderTapPreset preset in ReaderTapPreset.values) {
      final List<ReaderTapAction> candidate = ReaderTapLayout.preset(preset)
          .actions;
      if (List<int>.generate(
        9,
        (int i) => i,
      ).every((int i) => actions[i] == candidate[i])) {
        return preset;
      }
    }
    return null;
  }

  /// Coordinates are normalized to the page viewport, not the whole display.
  /// Keep the old inclusive middle-third boundaries exactly as they were.
  ReaderTapAction actionAt(double x, double y) {
    if (!x.isFinite || !y.isFinite) return ReaderTapAction.none;
    int third(double value) => value < 1 / 3 ? 0 : (value > 2 / 3 ? 2 : 1);
    return actions[third(y) * 3 + third(x)];
  }
}
