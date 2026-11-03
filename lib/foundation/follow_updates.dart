import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;
  final bool rateLimited;

  ComicUpdateResult(
    this.updated,
    this.errorMessage, {
    this.rateLimited = false,
  });
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  String folder, {
  bool Function()? shouldCancel,
  bool markNewUpdates = true,
}) async {
  ComicUpdateResult failed(String message, {bool rateLimited = false}) {
    LocalFavoritesManager().recordFailedUpdateAttempt(folder, c.id, c.type);
    return ComicUpdateResult(false, message, rateLimited: rateLimited);
  }

  int retries = 3;
  while (true) {
    try {
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return failed("Comic source not found");
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author:
            newInfo.subTitle ?? newInfo.tags['author']?.firstOrNull ?? c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updateTime = newInfo.findUpdateTime();
      // MangaDex used to expose the manga metadata timestamp. The bundled
      // source now exposes a chapter marker instead; migrate that value
      // without reporting a phantom update for existing favorites.
      var isMangaDexMarkerMigration =
          c.type.sourceKey == "manga_dex" &&
          c.updateTime != null &&
          DateTime.tryParse(c.updateTime!) != null &&
          updateTime?.contains("|") == true;
      final updated = LocalFavoritesManager().updateUpdateTime(
        folder,
        c.id,
        c.type,
        updateTime,
        // Only the first check establishes a silent baseline. Revisiting a
        // tracked folder must still report chapters added while it was away.
        markNewUpdate:
            (markNewUpdates || c.lastCheckTime != null) &&
            !isMangaDexMarkerMigration,
        chapterIds: newInfo.chapters?.ids.toList(),
      );
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      if (shouldCancel?.call() == true) return ComicUpdateResult(false, null);
      Log.error("Check Updates", e, s);
      retries--;
      final message = e.toString();
      // Source errors cross the JS boundary as strings, without HTTP metadata.
      final rateLimited = RegExp(
        r'(?:status(?:\s+code)?|http)[:\s]+429\b|\btoo many requests\b',
        caseSensitive: false,
      ).hasMatch(message);
      if (retries == 0 || rateLimited) {
        return failed(message, rateLimited: rateLimited);
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
}

Future<void> updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime, {
  required bool Function() shouldCancel,
  bool markNewUpdates = true,
  BackgroundTask? backgroundTask,
  Future<void> Function()? onComplete,
}) => DataSync().batchAutomaticUploads(
  () => _updateFolderBase(
    folder,
    stream,
    ignoreCheckTime,
    shouldCancel: shouldCancel,
    markNewUpdates: markNewUpdates,
    backgroundTask: backgroundTask,
    onComplete: onComplete,
  ),
);

Future<void> _updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime, {
  required bool Function() shouldCancel,
  bool markNewUpdates = true,
  BackgroundTask? backgroundTask,
  Future<void> Function()? onComplete,
}) async {
  void report(UpdateProgress progress) {
    backgroundTask?.update(
      completed: progress.current,
      total: progress.total,
      message: backgroundTask.cancelRequested
          ? 'Cancelling...'
          : progress.comic?.name ?? folder,
    );
    if (progress.errorMessage != null) {
      backgroundTask?.addError(
        '${progress.comic?.name ?? folder}: ${progress.errorMessage}',
      );
    }
    stream.add(progress);
  }

  var completionMessage = 'Update check completed';
  try {
    var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
    final total = comics.length;
    int current = 0;
    int errors = 0;
    int updated = 0;

    report(UpdateProgress(total, current, errors, updated));

    var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];
    var checkIntervalValue =
        appdata.settings['followUpdatesCheckIntervalHours'];
    var checkIntervalHours = checkIntervalValue is num
        ? checkIntervalValue.toInt()
        : 24;
    if (checkIntervalHours < 1) {
      checkIntervalHours = 1;
    }
    var checkInterval = Duration(hours: checkIntervalHours);

    for (var comic in comics) {
      if (!ignoreCheckTime) {
        var lastCheckTime = comic.lastCheckTime;
        final lastAttemptTime = comic.lastAttemptTime;
        if (lastAttemptTime != null &&
            (lastCheckTime == null || lastAttemptTime.isAfter(lastCheckTime))) {
          lastCheckTime = lastAttemptTime;
        }
        if (lastCheckTime != null &&
            DateTime.now().difference(lastCheckTime) < checkInterval) {
          current++;
          report(UpdateProgress(total, current, errors, updated));
          continue;
        }
      }
      comicsToUpdate.add(comic);
    }

    completionMessage = total == 0
        ? 'No comics to check'
        : 'Update check completed: checked @checked, skipped @skipped'.tlParams(
            {'checked': comicsToUpdate.length, 'skipped': current},
          );

    var channel = Channel<FavoriteItemWithUpdateInfo>(10);

    // Producer
    () async {
      var c = 0;
      for (var comic in comicsToUpdate) {
        if (shouldCancel()) break;
        await channel.push(comic);
        c++;
        // Throttle
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    // A rate-limited source is paused for the rest of this batch. Other
    // sources keep running; a later scheduled or manual check can retry it.
    final rateLimitedSources = <String, String>{};
    // Consumers
    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var comic = await channel.pop();
          if (comic == null) {
            break;
          }
          if (shouldCancel()) break;
          final sourceKey = comic.type.sourceKey;
          final rateLimitError = rateLimitedSources[sourceKey];
          final ComicUpdateResult result;
          if (rateLimitError != null) {
            LocalFavoritesManager().recordFailedUpdateAttempt(
              folder,
              comic.id,
              comic.type,
            );
            result = ComicUpdateResult(
              false,
              rateLimitError,
              rateLimited: true,
            );
          } else {
            result = await updateComic(
              comic,
              folder,
              shouldCancel: shouldCancel,
              markNewUpdates: markNewUpdates,
            );
            if (result.rateLimited) {
              rateLimitedSources[sourceKey] = result.errorMessage!;
            }
          }
          current++;
          if (result.updated) {
            updated++;
          }
          if (result.errorMessage != null) {
            errors++;
          }
          report(
            UpdateProgress(
              total,
              current,
              errors,
              updated,
              comic,
              result.errorMessage,
            ),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    if (updated > 0) {
      LocalFavoritesManager().notifyChanges();
    }
    if (!shouldCancel()) await onComplete?.call();
  } catch (e, s) {
    if (!shouldCancel()) {
      backgroundTask?.fail(e);
      stream.addError(e, s);
    }
  } finally {
    if (shouldCancel()) backgroundTask?.cancelRequested = true;
    backgroundTask?.onCancel = null;
    backgroundTask?.finish(
      message: shouldCancel() ? 'Cancelled' : completionMessage,
    );
    await stream.close();
  }
}

final _activeFolderChecks = <String, void Function()>{};

Stream<UpdateProgress> updateFolder(
  String folder,
  bool ignoreCheckTime, {
  bool Function()? shouldCancel,
  void Function()? onCancel,
  bool markNewUpdates = true,
  Future<void> Function()? onComplete,
}) {
  _activeFolderChecks[folder]?.call();
  final taskKey = 'follow-updates:$folder';
  final previous = BackgroundTasks.instance.latest(taskKey);
  if (previous?.isRunning == true && previous!.cancelRequested) {
    // A replacement takes ownership of this folder; late replies from the old
    // check are already ignored by updateComic's cancellation checks.
    previous.onCancel = null;
    previous.finish(message: 'Cancelled');
  }
  final task = BackgroundTasks.instance.start(
    taskKey,
    'Follow Updates: $folder',
    cancellable: true,
  );
  var canceled = false;
  void cancel() {
    if (canceled) return;
    canceled = true;
    if (task.isRunning) {
      onCancel?.call();
      task.cancelRequested = true;
      task.update(message: 'Cancelling...');
    }
  }

  task.onCancel = cancel;
  _activeFolderChecks[folder] = cancel;
  final stream = StreamController<UpdateProgress>(onCancel: cancel);
  unawaited(
    updateFolderBase(
      folder,
      stream,
      ignoreCheckTime,
      shouldCancel: () => canceled || shouldCancel?.call() == true,
      markNewUpdates: markNewUpdates,
      backgroundTask: task,
      onComplete: onComplete,
    ).whenComplete(() {
      if (identical(_activeFolderChecks[folder], cancel)) {
        _activeFolderChecks.remove(folder);
      }
    }),
  );
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'type': c.type.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
