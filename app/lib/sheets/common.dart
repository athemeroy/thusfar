import 'package:flutter/material.dart';

import '../reader/reader_controller.dart';

/// What drawers can ask the reader to do.
class ReaderLink {
  const ReaderLink({
    required this.c,
    required this.jump,
    required this.openAsk,
  });

  final ReaderController c;

  /// Closes every drawer, shows [offset] and offers the way back.
  final void Function(int offset, {(int, int)? highlight}) jump;

  /// Opens 问书, optionally with a prefilled question or quoted text.
  final void Function({String? prefill, String? quote}) openAsk;

  int pageNo(int offset) => c.pager!.pageNumberOf(offset);
}

Widget emptyState(BuildContext context, String text, {Widget? action}) =>
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 36, 28, 12),
        child: Column(
          children: <Widget>[
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.6,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (action != null) ...<Widget>[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
