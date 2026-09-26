import 'package:thusfar_core/src/pipeline/kg.dart' as kg;
import 'package:thusfar_core/src/pipeline/link.dart' as link;

import '../golden/codec.dart';

typedef Json = Map<String, Object?>;

Map<String, Set<String>> stringSets(Json values) => <String, Set<String>>{
  for (final MapEntry<String, Object?> e in values.entries)
    e.key: (e.value! as Iterable<Object?>).cast<String>().toSet(),
};

kg.KG graph(Json fields) {
  final kg.KG result = kg.KG(<String, Object?>{
    ...fields['book'] as Json? ?? <String, Object?>{},
    if (fields['k'] != null) 'card_lang': fields['k'] == 3 ? 'en' : 'zh',
  });
  result.people = <String, Json>{
    for (final MapEntry<String, Object?> e
        in (fields['people']! as Json).entries)
      e.key: <String, Object?>{
        ...e.value! as Json,
        'aliases':
            ((e.value! as Json)['aliases']! as Iterable<Object?>)
                .cast<String>()
                .toSet(),
        if ((e.value! as Json)['weak'] != null)
          'weak':
              ((e.value! as Json)['weak']! as Iterable<Object?>)
                  .cast<String>()
                  .toSet(),
      },
  };
  return result;
}

final Map<String, Object? Function(Json)> linkAdapters =
    <String, Object? Function(Json)>{
      'pipeline.link.is_generic':
          (Json i) => guard(() => link.isGeneric(i['name']! as String)),
      'pipeline.link.strong_names':
          (Json i) => guard(() => link.strongNames(i['p']! as Json)),
      'pipeline.link.weak_names':
          (Json i) => guard(() => link.weakNames(i['p']! as Json)),
      'pipeline.link.core':
          (Json i) => guard(() => link.core(i['name'] as String?)),
      'pipeline.link._tokens':
          (Json i) => guard(() => link.tokens(i['name']! as String)),
      'pipeline.link._stem':
          (Json i) => guard(() => link.stem(i['name']! as String)),
      'pipeline.link.related':
          (Json i) => guard(
            () => link.related(i['new']! as String, i['known']! as String),
          ),
      'pipeline.link.proper_name':
          (Json i) => guard(() => link.properName(i['p']! as Json)),
      'pipeline.link.names_of':
          (Json i) => guard(() => link.namesOf(i['p']! as Json)),
      'pipeline.link.short_forms':
          (Json i) => guard(() => link.shortForms(i['name']! as String)),
      'pipeline.link._gender_clash':
          (Json i) =>
              guard(() => link.genderClash(i['lp']! as Json, i['gp']! as Json)),
      'pipeline.link._resolve_hint':
          (Json i) => guard(
            () => link.resolveHint(
              graph((i['kg']! as Json)['fields']! as Json),
              i['lp']! as Json,
              stringSets(i['by_name']! as Json),
            ),
          ),
      'pipeline.link.to_classic':
          (Json i) => guard(
            () => link.toClassic(
              i['local']! as Json,
              i['decisions']! as Json,
              drop: i['drop'] == null ? null : stringSets(i['drop']! as Json),
              k: i['k']! as int,
            ),
          ),
    };
