import 'dart:convert';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/translations.dart';

String searchOptionsSchema(List<SearchOptions> options) => jsonEncode([
  for (final option in options)
    [option.label, option.type, option.options.keys.toList()],
]);

List<String>? validatedSearchOptions(
  List<SearchOptions> definitions,
  List<String> values,
) {
  if (definitions.length != values.length) return null;
  final result = <String>[];
  for (var i = 0; i < definitions.length; i++) {
    final definition = definitions[i];
    final value = values[i];
    if (definition.type == 'multi-select') {
      try {
        final selected = jsonDecode(value);
        if (selected is! List ||
            selected.any(
              (v) => v is! String || !definition.options.containsKey(v),
            )) {
          return null;
        }
        final keys = selected.cast<String>().toSet().toList()..sort();
        result.add(jsonEncode(keys));
      } catch (_) {
        return null;
      }
    } else {
      if (!definition.options.containsKey(value) &&
          !(value.isEmpty && definition.options.isEmpty)) {
        return null;
      }
      result.add(value);
    }
  }
  return result;
}

List<String> searchOptionLabels(
  List<SearchOptions> definitions,
  List<String> values,
  String sourceKey,
) => [
  for (var i = 0; i < definitions.length; i++)
    '${definitions[i].label.ts(sourceKey)}: ${definitions[i].type == 'multi-select' ? (jsonDecode(values[i]) as List).map((v) => (definitions[i].options[v] ?? v.toString()).ts(sourceKey)).join(', ') : (definitions[i].options[values[i]] ?? values[i]).ts(sourceKey)}',
];

List<String> defaultSearchOptions(List<SearchOptions> definitions) => [
  for (final definition in definitions) _defaultValue(definition),
];

String _defaultValue(SearchOptions definition) {
  var value = definition.defaultValue;
  if (definition.type == 'multi-select') {
    return validatedSearchOptions([definition], [value])?.single ?? '[]';
  }
  if (definition.options.containsKey(value)) return value;
  try {
    final decoded = jsonDecode(value);
    if (decoded is String && definition.options.containsKey(decoded)) {
      return decoded;
    }
  } catch (_) {}
  return definition.options.keys.firstOrNull ?? '';
}
