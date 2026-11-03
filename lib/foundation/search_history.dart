import 'dart:convert';

class SearchHistoryEntry {
  final String keyword;

  /// null is a legacy keyword; an empty string means aggregated search.
  final String? sourceKey;
  final String sourceName;
  final List<String> options;
  final List<String> labels;
  final String schema;
  final int page;

  SearchHistoryEntry({
    required this.keyword,
    this.sourceKey,
    this.sourceName = '',
    List<String> options = const [],
    List<String> labels = const [],
    this.schema = '',
    this.page = 1,
  }) : options = List.unmodifiable(options),
       labels = List.unmodifiable(labels);

  bool get isAggregate => sourceKey == '';
  bool get isLegacy => sourceKey == null;
  String get identity => jsonEncode([keyword, sourceKey, options]);
  SearchHistoryEntry atPage(int value) => SearchHistoryEntry(
    keyword: keyword,
    sourceKey: sourceKey,
    sourceName: sourceName,
    options: options,
    labels: labels,
    schema: schema,
    page: value,
  );

  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'source': sourceKey,
    'name': sourceName,
    'options': options,
    'labels': labels,
    'schema': schema,
    'page': page,
  };

  static SearchHistoryEntry? fromJson(dynamic value) {
    if (value is! Map) return null;
    final word = value['keyword'];
    final source = value['source'];
    final name = value['name'];
    final options = value['options'];
    final labels = value['labels'];
    final schema = value['schema'];
    final page = value['page'];
    bool validList(dynamic v) =>
        v is List &&
        v.length <= 64 &&
        v.every((e) => e is String && e.length <= 4096);
    if (word is! String ||
        word.trim().isEmpty ||
        word.length > 4096 ||
        source is! String ||
        source.length > 512 ||
        name is! String ||
        name.length > 512 ||
        !validList(options) ||
        !validList(labels) ||
        schema is! String ||
        schema.length > 65536 ||
        page is! int ||
        page < 1 ||
        page > 1000000) {
      return null;
    }
    return SearchHistoryEntry(
      keyword: word,
      sourceKey: source,
      sourceName: name,
      options: List<String>.from(options),
      labels: List<String>.from(labels),
      schema: schema,
      page: source.isEmpty ? 1 : page,
    );
  }

  static List<SearchHistoryEntry> decode(dynamic value) {
    if (value is! List) return [];
    final result = <SearchHistoryEntry>[];
    final ids = <String>{};
    for (final item in value) {
      final entry = fromJson(item);
      if (entry != null && ids.add(entry.identity)) result.add(entry);
      if (result.length == 50) break;
    }
    return result;
  }
}
