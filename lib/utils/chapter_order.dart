import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'chapter_title_sort.dart';

enum ChapterOrder {
  source('Source order'),
  reverse('Reversed source order'),
  titleAscending('Chapter title ascending'),
  titleDescending('Chapter title descending');

  const ChapterOrder(this.label);
  final String label;

  static ChapterOrder forComic(String id, String sourceKey) {
    final saved = appdata.settings['comicChapterOrder'];
    final value = saved is Map ? saved['$id@$sourceKey'] : null;
    return values.firstWhere(
      (order) => order.name == value,
      orElse: () =>
          appdata.settings['reverseChapterOrder'] == true ? reverse : source,
    );
  }

  void save(String id, String sourceKey) {
    final saved = appdata.settings['comicChapterOrder'];
    appdata.settings['comicChapterOrder'] = <String, dynamic>{
      if (saved is Map) ...Map<String, dynamic>.from(saved),
      '$id@$sourceKey': name,
    };
    appdata.saveData();
  }

  /// Reorder raw indexes only; chapter IDs and stored history never change.
  List<int> apply(Iterable<int> indexes, Iterable<String> titles) {
    final result = indexes.toList();
    if (this == source) return result;
    if (this == reverse) return result.reversed.toList();
    final names = titles.toList();
    final keys = {
      for (final index in result) index: ChapterTitleSortKey(names[index]),
    };
    result.sort((a, b) {
      final compared = keys[a]!.compareTo(keys[b]!);
      if (compared == 0) return a.compareTo(b);
      return this == titleDescending ? -compared : compared;
    });
    return result;
  }
}

/// Source-declared chronology, independent of every directory display option.
class ChapterSequence {
  const ChapterSequence({this.descending = false});
  final bool descending;

  int lastChapter(ComicChapters? chapters) {
    if (chapters == null) return 1;
    var offset = 0;
    var last = 1;
    final groups = chapters.isGrouped
        ? chapters.groups.map(chapters.getGroup)
        : [chapters.allChapters];
    for (final group in groups) {
      if (group.isNotEmpty) {
        last = descending ? offset + 1 : offset + group.length;
      }
      offset += group.length;
    }
    return last;
  }

  /// Resolve a neighbour within the same group, using 1-based raw indexes.
  int? adjacent(ComicChapters? chapters, int current, {required bool forward}) {
    if (chapters == null) return null;
    var start = 0;
    final groups = chapters.isGrouped
        ? chapters.groups.map(chapters.getGroup)
        : [chapters.allChapters];
    for (final group in groups) {
      final end = start + group.length;
      if (current > start && current <= end) {
        final step = (forward ? 1 : -1) * (descending ? -1 : 1);
        final target = current + step;
        return target > start && target <= end ? target : null;
      }
      start = end;
    }
    return null;
  }
}
