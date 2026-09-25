import 'package:thusfar_core/src/pipeline/lang.dart' as lang;
import 'package:thusfar_core/src/pipeline/provenance.dart' as provenance;
import 'package:thusfar_core/src/server/storage.dart' as storage;

import 'codec.dart';

typedef Json = Map<String, Object?>;

Map<String, Object? Function(Json)>
a1Adapters = <String, Object? Function(Json)>{
  'pipeline.lang.book_lang':
      (Json i) => guard(() => lang.bookLang(i['book']! as Json)),
  'pipeline.lang.seg_chars':
      (Json i) => guard(() => lang.segChars(i['book']! as Json)),
  'pipeline.provenance.digest':
      (Json i) => guard(() => provenance.digest(i['value'])),
  'pipeline.provenance.source_fingerprint':
      (Json i) => guard(
        () => provenance.sourceFingerprint(
          i['book']! as Json,
          i['segs']! as List<Object?>,
        ),
      ),
  'server.storage.asset_name':
      (Json i) => guard(() => storage.assetName(i['name'])),
  'server.storage.decode_assets':
      (Json i) =>
          guard(() => storage.decodeAssets(i['assets'], i['book']! as Json)),
  'server.storage.display_title':
      (Json i) => guard(
        () =>
            storage.displayTitle(i['title'] as String?, i['author'] as String?),
      ),
  'server.storage.integer':
      (Json i) => guard(
        () => storage.integer(
          i['value'],
          i['label']! as String,
          low: (i['low'] as int?) ?? 0,
          high: (i['high'] as int?) ?? 120000000,
        ),
      ),
  'server.storage.referenced_assets':
      (Json i) => guard(() => storage.referencedAssets(i['book']! as Json)),
  'server.storage.shelf_fields':
      (Json i) => guard(() => storage.shelfFields(i['book']! as Json)),
  'server.storage.validate_book':
      (Json i) => guard(() => storage.validateBook(i['book'])),
  'server.storage.validate_graph':
      (Json i) =>
          guard(() => storage.validateGraph(i['kg'], i['length']! as int)),
};
