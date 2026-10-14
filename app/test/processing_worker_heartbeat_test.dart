import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/processing_worker_heartbeat.dart';

void main() {
  test(
    'worker heartbeat is durable, bounded and independent of UI receipt',
    () {
      final Directory root = Directory.systemTemp.createTempSync(
        'worker-beat-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      int wall = 1000;
      int elapsed = 0;
      final ProcessingWorkerHeartbeat heartbeat = ProcessingWorkerHeartbeat(
        root,
        nowMs: () => wall,
        elapsedMs: () => elapsed,
      );
      for (int i = 0; i < 80; i++) {
        wall += 15000;
        elapsed += 15000;
        heartbeat.record();
      }
      // A backwards wall-clock correction must not conceal a timer gap.
      wall -= 300000;
      elapsed += 252000;
      final Map<String, Object?> last = heartbeat.record(finished: true);
      expect(last['gap_ms'], 252000);
      final Map<String, Object?> saved =
          jsonDecode(
                File(
                  '${root.path}/work/worker-heartbeat.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final List<Object?> rows = saved['samples']! as List<Object?>;
      expect(rows, hasLength(64));
      expect(rows.last, last);
      expect(last.keys.toSet(), <String>{
        'pid',
        'sequence',
        'at_ms',
        'elapsed_ms',
        'gap_ms',
        'finished',
      });
    },
  );

  test('diagnostic write failure cannot fail model work', () {
    final Directory root = Directory.systemTemp.createTempSync('worker-beat-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/work').writeAsStringSync('blocks directory creation');
    expect(ProcessingWorkerHeartbeat(root).record()['sequence'], 1);
  });
}
