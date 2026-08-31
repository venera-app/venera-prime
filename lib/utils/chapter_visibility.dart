import 'package:venera/foundation/comic_source/comic_source.dart';

abstract final class ChapterVisibility {
  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool _isDuplicate(Set<String> seen, String id, String title) {
    return !seen.add('$id\u0000${_normalize(title)}');
  }

  static List<int> flat(
    ComicChapters chapters, {
    required bool hideDuplicates,
  }) {
    final ids = chapters.ids.toList();
    final titles = chapters.titles.toList();
    final seen = <String>{};
    return [
      for (var i = 0; i < ids.length; i++)
        if (!hideDuplicates || !_isDuplicate(seen, ids[i], titles[i])) i,
    ];
  }

  static List<List<int>> grouped(
    ComicChapters chapters, {
    required bool hideDuplicates,
  }) {
    final seen = <String>{};
    return [
      for (var groupIndex = 0; groupIndex < chapters.groupCount; groupIndex++)
        [
          for (var i = 0; i < chapters.getGroupByIndex(groupIndex).length; i++)
            if (!hideDuplicates ||
                !_isDuplicate(
                  seen,
                  chapters.getGroupByIndex(groupIndex).keys.elementAt(i),
                  chapters.getGroupByIndex(groupIndex).values.elementAt(i),
                ))
              i,
        ],
    ];
  }
}
