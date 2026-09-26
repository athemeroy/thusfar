import 'package:thusfar_core/book_policy.dart' as policy;

import 'codec.dart';

typedef Json = Map<String, Object?>;

final Map<String, Object? Function(Json)>
policyAdapters = <String, Object? Function(Json)>{
  'pipeline.kind._cn':
      (Json input) => guard(() => policy.chineseNumber(input['s']! as String)),
  'pipeline.kind.ordinal':
      (Json input) => guard(() => policy.ordinal(input['title'] as String?)),
  'pipeline.kind.works':
      (Json input) => guard(
        () => policy.works(
          input['book']! as Json,
          minChars: input['min_chars']! as int,
        ),
      ),
};
