import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/utils/archive_security.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

Object? _redactSourceSecrets(Object? value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final normalized = key.toLowerCase().replaceAll('-', '_');
      final compact = normalized.replaceAll('_', '');
      if (compact == 'account' ||
          compact == 'password' ||
          compact == 'passwd' ||
          compact == 'pwd' ||
          compact == 'token' ||
          compact == 'authorization' ||
          compact == 'cookie' ||
          compact == 'apikey' ||
          compact.contains('token') ||
          compact.contains('secret')) {
        continue;
      }
      result[key] = _redactSourceSecrets(entry.value);
    }
    return result;
  }
  if (value is List) {
    return value.map(_redactSourceSecrets).toList();
  }
  return value;
}

String _safeImportedTable(String name) {
  if (name.isEmpty ||
      name.length > 128 ||
      name.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw const FormatException('Invalid imported table name');
  }
  return '"${name.replaceAll('"', '""')}"';
}

Future<File> exportAppData([bool sync = true]) async {
  // Always materialize the redacted sync snapshot. Manual backups must not
  // accidentally fall back to the full settings file.
  await appdata.saveData(false);
  var time = DateTime.now().microsecondsSinceEpoch;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    final manifestFiles = <String>[];
    Uint8List readStableFile(String path) {
      Object? lastError;
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          return File(path).readAsBytesSync();
        } catch (error) {
          lastError = error;
          sleep(const Duration(milliseconds: 20));
        }
      }
      throw lastError ?? StateError('Unable to read $path');
    }

    void addStableFile(String name, String path, {bool optional = false}) {
      if (!File(path).existsSync()) {
        if (optional) return;
        throw StateError('Backup file does not exist: $path');
      }
      zipFile.addFileFromBytes(name, readStableFile(path));
      manifestFiles.add(name);
    }

    void addRedactedSourceFile(String name, String path) {
      final bytes = readStableFile(path);
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        final redacted = jsonEncode(_redactSourceSecrets(decoded));
        zipFile.addFileFromBytes(name, utf8.encode(redacted));
      } catch (error) {
        throw FormatException('Source data is not valid JSON: $path', error);
      }
      manifestFiles.add(name);
    }

    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var readLaterFile = FilePath.join(dataPath, "read_later.db");
    var statisticsFile = FilePath.join(dataPath, "reading_statistics.db");
    var appdataFile = FilePath.join(dataPath, "syncdata.json");
    addStableFile("history.db", historyFile);
    addStableFile("local_favorite.db", localFavoriteFile);
    addStableFile("read_later.db", readLaterFile, optional: true);
    addStableFile("reading_statistics.db", statisticsFile, optional: true);
    addStableFile("appdata.json", appdataFile);
    final sourceDirectory = Directory(FilePath.join(dataPath, "comic_source"));
    if (sourceDirectory.existsSync()) {
      for (var file in sourceDirectory.listSync()) {
        if (file is File) {
          final name = file.name;
          if (name.endsWith('.tmp') || name.endsWith('.bak')) {
            continue;
          }
          if (name.endsWith('.data')) {
            addRedactedSourceFile("comic_source/$name", file.path);
          } else {
            addStableFile("comic_source/$name", file.path);
          }
        }
      }
    }
    zipFile.addFileFromBytes(
      'manifest.json',
      utf8.encode(jsonEncode({'format': 1, 'files': manifestFiles})),
    );
    zipFile.close();
  });
  return cacheFile;
}

Future<void> importAppData(File file, [bool checkVersion = false]) async {
  var cacheDirPath = FilePath.join(
    App.cachePath,
    'temp_data_${DateTime.now().microsecondsSinceEpoch}',
  );
  var cacheDir = Directory(cacheDirPath);
  await cacheDir.create(recursive: true);
  try {
    await ArchiveSecurity.extract(file, cacheDir);
    await _sanitizeBackupSources(cacheDir);
    _validateBackupManifest(cacheDir);
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var readLaterFile = cacheDir.joinFile("read_later.db");
    var statisticsFile = cacheDir.joinFile("reading_statistics.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    _validateBackupJson(appdataFile);
    _validateBackupDatabase(historyFile, 'history');
    _validateBackupDatabase(localFavoriteFile, 'local_favorite');
    if (await readLaterFile.exists()) {
      _validateBackupDatabase(readLaterFile, 'read_later');
    }
    if (await statisticsFile.exists()) {
      _validateBackupDatabase(statisticsFile, 'reading_statistics');
    }
    if (checkVersion && appdataFile.existsSync()) {
      var data = jsonDecode(await appdataFile.readAsString());
      var version = data is Map ? (data["settings"]?['dataVersion']) : null;
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return;
      }
    }
    await _commitBackup(
      cacheDir,
      historyFile,
      localFavoriteFile,
      readLaterFile,
      statisticsFile,
      appdataFile,
    );
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

void _validateBackupManifest(Directory staging) {
  final manifest = staging.joinFile('manifest.json');
  if (!manifest.existsSync()) {
    // Backups created before the manifest was introduced remain importable.
    return;
  }
  final decoded = jsonDecode(manifest.readAsStringSync());
  if (decoded is! Map || decoded['format'] != 1 || decoded['files'] is! List) {
    throw const FormatException('Backup manifest has an invalid structure');
  }
  final listed = <String>{};
  for (final value in decoded['files'] as List) {
    if (value is! String || value.isEmpty || value.length > 512) {
      throw const FormatException('Backup manifest contains an invalid path');
    }
    if (!listed.add(value)) {
      throw const FormatException('Backup manifest contains duplicate paths');
    }
    final path = ArchiveSecurity.safeTarget(staging.path, value);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Backup manifest references a missing file');
    }
  }
  const required = ['history.db', 'local_favorite.db', 'appdata.json'];
  if (required.any((name) => !listed.contains(name))) {
    throw const FormatException('Backup manifest is missing required files');
  }
}

Future<void> _sanitizeBackupSources(Directory staging) async {
  final sourceDir = Directory(FilePath.join(staging.path, 'comic_source'));
  if (!await sourceDir.exists()) return;
  await for (final entity in sourceDir.list(
    recursive: true,
    followLinks: false,
  )) {
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Backup contains a symbolic link');
    }
    if (entity is! File) continue;
    final name = entity.name.toLowerCase();
    try {
      await entity.readAsBytes();
    } catch (_) {
      throw const FormatException('Backup source file is unreadable');
    }
    if (name.endsWith('.data')) {
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Source data must be a JSON object');
      }
      await entity.writeAsString(
        jsonEncode(_redactSourceSecrets(decoded)),
        flush: true,
      );
    } else if (name.endsWith('.js') &&
        (await entity.readAsString()).trim().isEmpty) {
      throw const FormatException('Source script is empty');
    }
  }
}

void _validateBackupJson(File file) {
  if (!file.existsSync()) {
    throw const FormatException('Backup is missing appdata.json');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map || decoded['settings'] is! Map) {
    throw const FormatException('Backup appdata.json has an invalid structure');
  }
}

void _validateBackupDatabase(File file, String name) {
  if (!file.existsSync()) {
    throw FormatException('Backup is missing $name database');
  }
  final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    final result = db.select('PRAGMA integrity_check;');
    if (result.isEmpty || result.first[0] != 'ok') {
      throw FormatException('Backup $name database failed integrity_check');
    }
  } finally {
    db.dispose();
  }
}

Future<void> _commitBackup(
  Directory staging,
  File historyFile,
  File favoriteFile,
  File readLaterFile,
  File statisticsFile,
  File appdataFile,
) async {
  final stamp = DateTime.now().millisecondsSinceEpoch.toString();
  final rollback = Directory(FilePath.join(App.cachePath, 'restore_$stamp'));
  await rollback.create(recursive: true);
  final names = <String>['history.db', 'local_favorite.db', 'appdata.json'];
  if (readLaterFile.existsSync()) names.add('read_later.db');
  if (statisticsFile.existsSync()) names.add('reading_statistics.db');
  final sourceDir = Directory(FilePath.join(staging.path, 'comic_source'));
  final targetSourceDir = Directory(
    FilePath.join(App.dataPath, 'comic_source'),
  );
  final oldSourceDir = Directory(FilePath.join(rollback.path, 'comic_source'));
  final replaceSources = sourceDir.existsSync();
  final oldAppdata = File(FilePath.join(rollback.path, 'appdata.json'));
  var cleanupRollback = true;
  try {
    HistoryManager().close();
    LocalFavoritesManager().close();
    ReadLaterManager().close();
    ReadingStatisticsManager().close();
    for (final name in names) {
      final current = File(FilePath.join(App.dataPath, name));
      if (current.existsSync()) {
        await current.rename(FilePath.join(rollback.path, name));
      }
    }
    if (replaceSources && targetSourceDir.existsSync()) {
      await targetSourceDir.rename(oldSourceDir.path);
    }
    await historyFile.rename(FilePath.join(App.dataPath, 'history.db'));
    await favoriteFile.rename(FilePath.join(App.dataPath, 'local_favorite.db'));
    if (readLaterFile.existsSync()) {
      await readLaterFile.rename(FilePath.join(App.dataPath, 'read_later.db'));
    }
    if (statisticsFile.existsSync()) {
      await statisticsFile.rename(
        FilePath.join(App.dataPath, 'reading_statistics.db'),
      );
    }
    await appdataFile.rename(FilePath.join(App.dataPath, 'appdata.json'));
    if (replaceSources) await sourceDir.rename(targetSourceDir.path);
    appdata.syncData(
      jsonDecode(
        await File(FilePath.join(App.dataPath, 'appdata.json')).readAsString(),
      ),
      persist: false,
    );
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await ReadLaterManager().init();
    await ReadingStatisticsManager().init();
    if (replaceSources) {
      await ComicSourceManager().reload();
    }
    await rollback.delete(recursive: true);
  } catch (error, stack) {
    var restored = true;
    for (final name in names.reversed) {
      try {
        final current = File(FilePath.join(App.dataPath, name));
        if (current.existsSync()) await current.delete();
        final old = File(FilePath.join(rollback.path, name));
        if (old.existsSync()) {
          await old.rename(current.path);
        }
      } catch (e, s) {
        restored = false;
        Log.error('Import Data', 'Failed to restore $name: $e', s);
      }
    }
    if (replaceSources) {
      try {
        if (targetSourceDir.existsSync()) {
          await targetSourceDir.delete(recursive: true);
        }
        if (oldSourceDir.existsSync()) {
          await oldSourceDir.rename(targetSourceDir.path);
        }
        // reload() clears the registry before parsing. Rebuild it from the
        // restored files so memory cannot remain on a partial failed state.
        await ComicSourceManager().reload();
      } catch (e, s) {
        restored = false;
        Log.error('Import Data', 'Failed to restore comic sources: $e', s);
      }
    }
    if (oldAppdata.existsSync()) {
      try {
        appdata.syncData(
          jsonDecode(await oldAppdata.readAsString()),
          persist: false,
        );
      } catch (e, s) {
        restored = false;
        Log.error('Import Data', 'Failed to restore appdata: $e', s);
      }
    }
    try {
      await HistoryManager().init();
      await LocalFavoritesManager().init();
      await ReadLaterManager().init();
      await ReadingStatisticsManager().init();
    } catch (e, s) {
      restored = false;
      Log.error('Import Data', 'Failed to reopen restored databases: $e', s);
    }
    if (!restored) {
      cleanupRollback = false;
      Log.error(
        'Import Data',
        'Restore failed; preserving rollback directory at ${rollback.path}',
      );
    }
    Error.throwWithStackTrace(error, stack);
  } finally {
    if (cleanupRollback && rollback.existsSync()) {
      await rollback.deleteIgnoreError(recursive: true);
    }
  }
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(
    App.cachePath,
    'temp_data_${DateTime.now().microsecondsSinceEpoch}',
  );
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await ArchiveSecurity.extract(file, cacheDir);
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"] as String)
            .toList();
        folderNames.removeWhere(
          (e) =>
              e == "folder_order" ||
              e == "folder_sync" ||
              (() {
                try {
                  _safeImportedTable(e);
                  return false;
                } catch (_) {
                  return true;
                }
              })(),
        );
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          var folderName = folderSyncValue["folder_name"];
          String sourceKey = folderSyncValue["key"];
          sourceKey = sourceKey.toLowerCase() == "htmanga"
              ? "wnacg"
              : sourceKey;
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(
              folderName,
              sourceKey,
              jsonDecode(folderSyncValue["sync_data"])["folderId"],
            );
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (var folderName in folderNames) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var comic in db.select(
            'SELECT * FROM ${_safeImportedTable(folderName)};',
          )) {
            LocalFavoritesManager().addComic(
              folderName,
              FavoriteItem(
                id: comic['target'],
                name: comic['name'],
                coverPath: comic['cover_path'],
                author: comic['author'],
                type: ComicType(switch (comic['type']) {
                  0 => 'picacg'.hashCode,
                  1 => 'ehentai'.hashCode,
                  2 => 'jm'.hashCode,
                  3 => 'hitomi'.hashCode,
                  4 => 'wnacg'.hashCode,
                  6 => 'nhentai'.hashCode,
                  _ => comic['type'],
                }),
                tags: comic['tags'].split(','),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.dispose();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": switch (comic['type']) {
                0 => 'picacg'.hashCode,
                1 => 'ehentai'.hashCode,
                2 => 'jm'.hashCode,
                3 => 'hitomi'.hashCode,
                4 => 'wnacg'.hashCode,
                5 => 'nhentai'.hashCode,
                _ => comic['type'],
              },
              "id": comic['target'],
              "max_page": comic["max_page"],
              "ep": comic["ep"],
              "page": comic["page"],
              "time": comic["time"],
              "title": comic["title"],
              "subtitle": comic["subtitle"],
              "cover": comic["cover"],
              "readEpisode": [comic["ep"]],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = comic["id"].split("-")[0];
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = comic["id"].split("-")[1];
          int page = comic["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = comic["ep"] == 0 ? 1 : comic["ep"];
          String title = comic["title"];
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.dispose();
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
