import 'dart:math';

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

enum RandomComicStatus { any, notStarted, inProgress, completed }

abstract final class RandomComicPicker {
  static ComicType _type(Comic comic) {
    if (comic.sourceKey == 'local') return ComicType.local;
    if (comic.sourceKey.startsWith('Unknown:')) {
      return ComicType(int.tryParse(comic.sourceKey.substring(8)) ?? 0);
    }
    return ComicType.fromKey(comic.sourceKey);
  }

  static bool _completed(Comic comic, History? history) {
    if (history == null) return false;
    if (comic is LocalComic && comic.chapters != null) {
      return history.readEpisode.length >= comic.chapters!.length;
    }
    return history.maxPage != null && history.page >= history.maxPage!;
  }

  static bool _matches(Comic comic, RandomComicStatus status) {
    final history = HistoryManager().find(comic.id, _type(comic));
    return switch (status) {
      RandomComicStatus.any => true,
      RandomComicStatus.notStarted => history == null,
      RandomComicStatus.completed => _completed(comic, history),
      RandomComicStatus.inProgress =>
        history != null && !_completed(comic, history),
    };
  }

  static Comic? pick(
    Iterable<Comic> comics, {
    RandomComicStatus status = RandomComicStatus.any,
    Random? random,
  }) {
    final candidates = <Comic>{
      for (final comic in comics)
        if (_matches(comic, status)) comic,
    }.toList();
    if (candidates.isEmpty) return null;
    return candidates[(random ?? Random()).nextInt(candidates.length)];
  }

  static List<Comic> favorites([String? folder]) {
    if (folder != null) {
      return LocalFavoritesManager().getFolderComics(folder).cast<Comic>();
    }
    return LocalFavoritesManager().getAllComics().cast<Comic>();
  }

  static List<Comic> history() => HistoryManager().getAll().cast<Comic>();

  static List<Comic> local() =>
      LocalManager().getComics(LocalSortType.timeDesc).cast<Comic>();
}
