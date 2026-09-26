import 'package:thusfar_core/src/pipeline/extract.dart' as extract;
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import 'package:thusfar_core/src/pipeline/local.dart' as local;

import 'codec.dart';

typedef Json = Map<String, Object?>;

Object _error(Object? encoded) {
  final Json e = (encoded! as Json)[r'$error']! as Json;
  return llm.LLMError(e['message']! as String);
}

Map<String, Object? Function(Json)>
engineAdapters = <String, Object? Function(Json)>{
  'pipeline.extract.segments':
      (Json i) => guard(
        () => extract.segments(
          i['book']! as Json,
          (i['body']! as List<Object?>).cast<int>(),
          maxChars: i['max_chars'] as int?,
        ),
      ),
  'pipeline.extract.seg_text':
      (Json i) =>
          guard(() => extract.segText(i['book']! as Json, i['seg']! as Json)),
  'pipeline.extract.registry_prompt':
      (Json i) => guard(
        () => extract.registryPrompt(i['state']! as Json, i['text']! as String),
      ),
  'pipeline.extract.relations_prompt':
      (Json i) => guard(
        () =>
            extract.relationsPrompt(i['state']! as Json, i['text']! as String),
      ),
  'pipeline.extract.build_messages':
      (Json i) => guard(
        () => extract.buildMessages(
          i['book']! as Json,
          i['state']! as Json,
          i['seg']! as Json,
        ),
      ),
  'pipeline.local.lang_note':
      (Json i) => guard(
        () => local.langNote(
          i['lang'] as String?,
          i['quote_lo']! as int,
          i['quote_hi']! as int,
          (i['output_lang'] as String?) ?? 'zh',
        ),
      ),
  'pipeline.local._s': (Json i) => guard(() => local.s(i['x'])),
  'pipeline.llm.parse_json':
      (Json i) => guard(() => llm.parseJson(i['text']! as String)),
  'pipeline.llm.repair_json':
      (Json i) => guard(() => llm.repairJson(i['s']! as String)),
  'pipeline.llm.explain':
      (Json i) => guard(() => llm.explain(_error(i['error']))),
  'pipeline.llm._state_text':
      (Json i) => guard(() => jev.stateText(i['state'])),
  'pipeline.llm._validate_answers':
      (Json i) => guard(
        () => jev.validateAnswers(
          i['answers'],
          i['questions']! as Json,
          i['route']! as String,
        ),
      ),
  'pipeline.llm._classifier_batches':
      (Json i) => guard(
        () => <Object?>[
          for (final (List<String> keys, Json dims) in jev.classifierBatches(
            i['questions']! as Json,
          ))
            (keys, dims),
        ],
      ),
};
