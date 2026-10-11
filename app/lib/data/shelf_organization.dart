/// Reader-owned shelf labels. These never change a book's reading position or
/// spoiler boundary. The same small model is used by native and Web backups.
class ShelfBookState {
  const ShelfBookState({this.collection, this.finished});

  final String? collection;
  final bool? finished;

  Map<String, Object?> toJson() => <String, Object?>{
    if (collection != null) 'collection': collection,
    if (finished != null) 'finished': finished,
  };

  static ShelfBookState fromJson(Map<String, Object?> value) => ShelfBookState(
    collection: value['collection'] as String?,
    finished: value['finished'] as bool?,
  );
}

class ShelfOrganization {
  ShelfOrganization({
    List<String>? collections,
    Map<String, ShelfBookState>? books,
  }) : collections = collections ?? <String>[],
       books = books ?? <String, ShelfBookState>{};

  final List<String> collections;
  final Map<String, ShelfBookState> books;

  factory ShelfOrganization.fromJson(Object? value) {
    if (value == null) return ShelfOrganization();
    if (value is! Map<String, Object?> ||
        value['books'] is! Map<String, Object?>) {
      throw const FormatException('书架分类格式无效。');
    }
    final Map<String, Object?> rawBooks =
        value['books']! as Map<String, Object?>;
    if (rawBooks.values.any((Object? row) => row is! Map<String, Object?>)) {
      throw const FormatException('书架中的书籍分类格式无效。');
    }
    final List<String> ids = rawBooks.keys.toList();
    final Map<String, Object?> portable = validatedShelfOrganization(
      <String, Object?>{
        'collections': value['collections'],
        'books': <Object?>[
          for (int i = 0; i < ids.length; i++)
            <String, Object?>{
              if (rawBooks[ids[i]] is Map<String, Object?>)
                ...rawBooks[ids[i]]! as Map<String, Object?>,
              'index': i,
            },
        ],
      },
    );
    return ShelfOrganization()..mergePortable(portable, ids);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'collections': List<String>.of(collections),
    'books': <String, Object?>{
      for (final MapEntry<String, ShelfBookState> item in books.entries)
        item.key: item.value.toJson(),
    },
  };

  Map<String, Object?> exportPortable(List<String> ids) => <String, Object?>{
    'collections': List<String>.of(collections),
    'books': <Object?>[
      for (int i = 0; i < ids.length; i++)
        if (books[ids[i]] case final ShelfBookState state)
          <String, Object?>{'index': i, ...state.toJson()},
    ],
  };

  /// Imported labels join this shelf. Unrepresented books keep their labels.
  void mergePortable(Object? value, List<String> ids) {
    final Map<String, Object?> safe = validatedShelfOrganization(
      value,
      bookCount: ids.length,
    );
    if (<String>{
          ...collections,
          ...(safe['collections']! as List<Object?>).cast<String>(),
        }.length >
        100) {
      throw const FormatException('合并后的分类超过 100 个，请先整理分类。');
    }
    for (final String name
        in (safe['collections']! as List<Object?>).cast<String>()) {
      if (!collections.contains(name)) collections.add(name);
    }
    for (final Object? raw in safe['books']! as List<Object?>) {
      final Map<String, Object?> row = raw! as Map<String, Object?>;
      books[ids[row['index']! as int]] = ShelfBookState.fromJson(row);
    }
  }
}

Map<String, Object?> validatedShelfOrganization(
  Object? value, {
  int bookCount = 2000,
}) {
  if (value is! Map<String, Object?> ||
      value.keys.any((key) => key != 'collections' && key != 'books') ||
      value['collections'] is! List<Object?> ||
      value['books'] is! List<Object?>) {
    throw const FormatException('书架分类格式无效。');
  }
  final List<Object?> names = value['collections']! as List<Object?>;
  final List<Object?> rows = value['books']! as List<Object?>;
  if (names.length > 100 ||
      rows.length > 2000 ||
      names.any(
        (name) =>
            name is! String ||
            name.trim().isEmpty ||
            name != name.trim() ||
            name.length > 30,
      ) ||
      names.toSet().length != names.length) {
    throw const FormatException('书架分类名称无效。');
  }
  final Set<int> seen = <int>{};
  final List<Map<String, Object?>> books = <Map<String, Object?>>[];
  for (final Object? raw in rows) {
    if (raw is! Map<String, Object?> ||
        raw.keys.any(
          (key) =>
              !const <String>{'index', 'collection', 'finished'}.contains(key),
        ) ||
        raw['index'] is! int) {
      throw const FormatException('书架分类中的书籍无效。');
    }
    final int index = raw['index']! as int;
    final Object? collection = raw['collection'];
    final Object? finished = raw['finished'];
    if (index < 0 ||
        index >= bookCount ||
        !seen.add(index) ||
        collection != null &&
            (collection is! String || !names.contains(collection)) ||
        finished != null && finished is! bool) {
      throw const FormatException('书架分类引用或阅读状态无效。');
    }
    books.add(<String, Object?>{
      'index': index,
      'collection': ?collection,
      'finished': ?finished,
    });
  }
  return <String, Object?>{
    'collections': List<String>.of(names.cast<String>()),
    'books': books,
  };
}
