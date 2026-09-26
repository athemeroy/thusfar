import 'package:thusfar_core/manual_entities.dart' as manual;
import 'package:thusfar_core/notebook.dart' as notebook;
import 'package:thusfar_core/reading_list.dart' as reading_list;

import 'codec.dart';

typedef Json = Map<String, Object?>;
List<Json> _maps(Object? value) => (value! as List<Object?>).cast<Json>();
double Function()? _clock(Json input) =>
    input['now'] is num ? () => (input['now']! as num).toDouble() : null;

final Map<String, Object? Function(Json)>
personalAdapters = <String, Object? Function(Json)>{
  'server.manual_entities.anchor':
      (Json input) => guard(
        () => manual.manualAnchor(
          input['book']! as Json,
          input['name']! as String,
          input['cutoff']! as int,
        ),
      ),
  'server.manual_entities._base':
      (Json input) =>
          guard(() => manual.manualBase(input['item'], input['book']! as Json)),
  'server.manual_entities.apply':
      (Json input) => guard(
        () => manual.manualApply(
          _maps(input['items']),
          input['payload']! as Json,
          input['book']! as Json,
          input['graph']! as Json,
          clock: _clock(input),
        ),
      ),
  'server.manual_entities.rows':
      (Json input) => guard(() => manual.manualRows(_maps(input['items']))),
  'server.manual_entities.mentions':
      (Json input) => guard(
        () => manual.manualMentions(
          _maps(input['blocks']),
          _maps(input['items']),
          (input['existing']! as List<Object?>).cast<List<Object?>>(),
        ),
      ),
  'server.manual_entities.restore':
      (Json input) => guard(
        () => manual.manualRestore(input['items'], input['book']! as Json),
      ),
  'server.notebook.source_quote':
      (Json input) => guard(
        () => notebook.sourceQuote(
          input['book']! as Json,
          input['start']! as int,
          input['end']! as int,
        ),
      ),
  'server.notebook.validate':
      (Json input) =>
          guard(() => notebook.validate(input['item'], input['book']! as Json)),
  'server.notebook.apply':
      (Json input) => guard(
        () => notebook.apply(
          input['items']! as List<Object?>,
          input['item']! as Json,
          input['book']! as Json,
          now: _clock(input),
        ),
      ),
  'server.notebook.restore':
      (Json input) => guard(
        () => notebook.restore(
          input['items'],
          input['book']! as Json,
          now: _clock(input),
        ),
      ),
  'server.reading_list.empty': (Json _) => guard(reading_list.empty),
  'server.reading_list.apply':
      (Json input) => guard(
        () => reading_list.apply(
          input['current']! as Json,
          input['payload']! as Json,
          (String id) => (input['visible']! as List<Object?>).contains(id),
          now: _clock(input),
        ),
      ),
};
