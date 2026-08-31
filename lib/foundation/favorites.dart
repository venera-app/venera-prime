import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_provider/local_favorite_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/tags_translation.dart';
import 'dart:io';

import 'app.dart';
import 'comic_source/comic_source.dart';
import 'comic_type.dart';

String _getTimeString(DateTime time) {
  return time.toIso8601String().replaceFirst("T", " ").substring(0, 19);
}

String _favoriteTable(String name) {
  if (name.isEmpty ||
      name.length > 128 ||
      name.contains('"') ||
      name.codeUnits.any((value) => value < 0x20 || value == 0x7f)) {
    throw const FormatException('Invalid favorite folder name');
  }
  return '"$name"';
}

String _importFavoriteString(
  Map<String, dynamic> json,
  String key, {
  String? fallbackKey,
  int maxLength = 4096,
  bool allowEmpty = true,
}) {
  final value = json[key] ?? (fallbackKey == null ? null : json[fallbackKey]);
  if (value is! String || value.length > maxLength) {
    throw FormatException('Invalid favorite field: $key');
  }
  if (!allowEmpty && value.isEmpty) {
    throw FormatException('Favorite field is empty: $key');
  }
  return value;
}

List<String> _importFavoriteTags(Object? value) {
  if (value is! List || value.length > 256) {
    throw const FormatException('Invalid favorite tags');
  }
  final tags = <String>[];
  var totalLength = 0;
  for (final tag in value) {
    if (tag is! String || tag.length > 1024) {
      throw const FormatException('Invalid favorite tag');
    }
    totalLength += tag.length;
    if (totalLength > 64 * 1024) {
      throw const FormatException('Favorite tags are too large');
    }
    tags.add(tag);
  }
  return tags;
}

class FavoriteItem implements Comic {
  String name;
  String author;
  ComicType type;
  @override
  List<String> tags;
  @override
  String id;
  String coverPath;
  late String time;

  FavoriteItem({
    required this.id,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
    DateTime? favoriteTime,
  }) {
    var t = favoriteTime ?? DateTime.now();
    time = _getTimeString(t);
  }

  FavoriteItem.fromRow(Row row)
    : name = row["name"],
      author = row["author"],
      type = ComicType(row["type"]),
      tags = (row["tags"] as String).split(","),
      id = row["id"],
      coverPath = row["cover_path"],
      time = row["time"] {
    tags.remove("");
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem && other.id == id && other.type == type;
  }

  @override
  int get hashCode => id.hashCode ^ type.hashCode;

  @override
  String toString() {
    var s = "FavoriteItem: $name $author $coverPath $hashCode $tags";
    if (s.length > 100) {
      return s.substring(0, 100);
    }
    return s;
  }

  @override
  String get cover => coverPath;

  @override
  String get description {
    var time = this.time.substring(0, 10);
    return appdata.settings['comicDisplayMode'] == 'detailed'
        ? "$time | ${type == ComicType.local ? 'local' : type.comicSource?.name ?? "Unknown"}"
        : "${type.comicSource?.name ?? "Unknown"} | $time";
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  int? get maxPage => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  String? get subtitle => author;

  @override
  String get title => name;

  @override
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "author": author,
      "type": type.value,
      "tags": tags,
      "id": id,
      "coverPath": coverPath,
    };
  }

  static FavoriteItem fromJson(Map<String, dynamic> json) {
    final rawType = json["type"];
    if (rawType is! int) {
      throw const FormatException('Invalid favorite type');
    }
    var type = rawType;
    final coverPath = _importFavoriteString(json, 'coverPath');
    if (type == 0 && coverPath.startsWith('http')) {
      type = 'picacg'.hashCode;
    } else if (type == 1) {
      type = 'ehentai'.hashCode;
    } else if (type == 2) {
      type = 'jm'.hashCode;
    } else if (type == 3) {
      type = 'hitomi'.hashCode;
    } else if (type == 4) {
      type = 'wnacg'.hashCode;
    } else if (type == 6) {
      type = 'nhentai'.hashCode;
    }
    return FavoriteItem(
      id: _importFavoriteString(
        json,
        'id',
        fallbackKey: 'target',
        maxLength: 1024,
        allowEmpty: false,
      ),
      name: _importFavoriteString(json, 'name', allowEmpty: false),
      author: _importFavoriteString(json, 'author'),
      coverPath: coverPath,
      type: ComicType(type),
      tags: _importFavoriteTags(json["tags"] ?? const <String>[]),
    );
  }
}

class FavoriteItemWithFolderInfo extends FavoriteItem {
  String folder;

  FavoriteItemWithFolderInfo(FavoriteItem item, this.folder)
    : super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
      );
}

class FavoriteItemWithUpdateInfo extends FavoriteItem {
  String? updateTime;

  DateTime? lastCheckTime;

  bool hasNewUpdate;

  FavoriteItemWithUpdateInfo(
    FavoriteItem item,
    this.updateTime,
    this.hasNewUpdate,
    int? lastCheckTime,
  ) : lastCheckTime = lastCheckTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheckTime),
      super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
      );

  @override
  String get description {
    var updateTime = this.updateTime ?? "Unknown";
    // Follow-updates markers may include an opaque chapter identity after
    // the display date (for example `2026-08-26|chapter|en`).
    if (updateTime.contains('|')) {
      updateTime = updateTime.split('|').first;
      // MangaDex markers use a zero-padded ISO date internally. Keep the
      // marker unchanged for comparisons, but match the app's date display
      // convention and omit padding from month/day in the visible label.
      final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(updateTime);
      if (date != null) {
        updateTime =
            '${date.group(1)}-${int.parse(date.group(2)!)}-${int.parse(date.group(3)!)}';
      }
    }
    var sourceName = type.comicSource?.name ?? "Unknown";
    return "$updateTime | $sourceName";
  }

  @override
  operator ==(Object other) {
    return other is FavoriteItemWithUpdateInfo &&
        other.updateTime == updateTime &&
        other.hasNewUpdate == hasNewUpdate &&
        super == other;
  }

  @override
  int get hashCode =>
      super.hashCode ^ updateTime.hashCode ^ hasNewUpdate.hashCode;
}

class LocalFavoritesManager with ChangeNotifier {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  late Database _db;

  late Map<String, int> counts;
  Future<void>? _initializing;
  bool isInitialized = false;

  var _hashedIds = <String, int>{};

  static String _identityKey(String id, int type) => '$type\u0000$id';

  int get totalComics {
    return _hashedIds.length;
  }

  int folderComics(String folder) {
    _favoriteTable(folder);
    return counts[folder] ?? 0;
  }

  Future<void> init() => _initializing ??= _initWithReset();

  Future<void> _initWithReset() async {
    try {
      await _initInternal();
    } catch (_) {
      _initializing = null;
      isInitialized = false;
      counts = {};
      _hashedIds = {};
      try {
        _db.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _initInternal() async {
    counts = {};
    _db = sqlite3.open("${App.dataPath}/local_favorite.db");
    _db.execute("""
      create table if not exists folder_order (
        folder_name text primary key,
        order_value int
      );
    """);
    _db.execute("""
      create table if not exists folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    """);
    var folderNames = _getFolderNamesWithDB();
    for (var folder in folderNames) {
      final table = _favoriteTable(folder);
      var columns = _db.select("""
        pragma table_info($table);
      """);
      if (!columns.any((element) => element["name"] == "translated_tags")) {
        _db.execute("""
          alter table $table
          add column translated_tags TEXT;
        """);
        var comics = getFolderComics(folder);
        for (var comic in comics) {
          var translatedTags = _translateTags(comic.tags);
          _db.execute(
            """
            update $table
            set translated_tags = ?
            where id == ? and type == ?;
          """,
            [translatedTags, comic.id, comic.type.value],
          );
        }
      }
    }
    await appdata.ensureInit();
    // Make sure the follow updates folder is ready
    var followUpdateFolder = appdata.settings['followUpdatesFolder'];
    if (followUpdateFolder is String &&
        folderNames.contains(followUpdateFolder)) {
      prepareTableForFollowUpdates(followUpdateFolder, false);
    } else {
      appdata.settings['followUpdatesFolder'] = null;
    }
    await initCounts();
    isInitialized = true;
  }

  Future<void> initCounts() async {
    for (var folder in folderNames) {
      counts[folder] = count(folder);
    }
    _hashedIds = await _initHashedIds(
      folderNames,
      "${App.dataPath}/local_favorite.db",
    );
    notifyListeners();
  }

  void refreshHashedIds() {
    _initHashedIds(folderNames, "${App.dataPath}/local_favorite.db").then(
      (value) {
        _hashedIds = value;
        notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        Log.error(
          'Favorites',
          'Failed to refresh identity cache: $error',
          stack,
        );
      },
    );
  }

  void reduceHashedId(String id, int type) {
    final identity = _identityKey(id, type);
    if (_hashedIds.containsKey(identity)) {
      if (_hashedIds[identity]! > 1) {
        _hashedIds[identity] = _hashedIds[identity]! - 1;
      } else {
        _hashedIds.remove(identity);
      }
    }
  }

  static Future<Map<String, int>> _initHashedIds(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        var hashedIds = <String, int>{};
        for (var folder in folders) {
          var rows = db.select(
            'select id, type from ${_favoriteTable(folder)};',
          );
          for (var row in rows) {
            var id = row["id"] as String;
            var type = row["type"] as int;
            final identity = _identityKey(id, type);
            hashedIds[identity] = (hashedIds[identity] ?? 0) + 1;
          }
        }
        return hashedIds;
      } finally {
        db.dispose();
      }
    });
  }

  List<String> find(String id, ComicType type) {
    var res = <String>[];
    for (var folder in folderNames) {
      final table = _favoriteTable(folder);
      var rows = _db.select(
        """
        select * from $table
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<List<String>> findWithModel(FavoriteItem item) async {
    var res = <String>[];
    for (var folder in folderNames) {
      final table = _favoriteTable(folder);
      var rows = _db.select(
        """
        select * from $table
        where id == ? and type == ?;
      """,
        [item.id, item.type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  List<String> _getTablesWithDB() {
    final tables = _db
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((element) => element["name"] as String)
        .toList();
    return tables;
  }

  List<String> _getFolderNamesWithDB() {
    final folders = _getTablesWithDB();
    folders.remove('folder_sync');
    folders.remove('folder_order');
    folders.removeWhere((folder) {
      try {
        _favoriteTable(folder);
        return false;
      } catch (_) {
        Log.warning('Favorites', 'Ignoring invalid favorite table name');
        return true;
      }
    });
    var folderToOrder = <String, int>{};
    for (var folder in folders) {
      var res = _db.select(
        """
        select * from folder_order
        where folder_name == ?;
      """,
        [folder],
      );
      if (res.isNotEmpty) {
        folderToOrder[folder] = res.first["order_value"];
      } else {
        folderToOrder[folder] = 0;
      }
    }
    folders.sort((a, b) {
      return folderToOrder[a]! - folderToOrder[b]!;
    });
    return folders;
  }

  void updateOrder(List<String> folders) {
    for (int i = 0; i < folders.length; i++) {
      _db.execute(
        """
        insert or replace into folder_order (folder_name, order_value)
        values (?, ?);
      """,
        [folders[i], i],
      );
    }
    notifyListeners();
  }

  int count(String folderName) {
    final table = _favoriteTable(folderName);
    return _db.select("""
      select count(*) as c
      from $table
    """).first["c"];
  }

  List<String> get folderNames => _getFolderNamesWithDB();

  int maxValue(String folder) {
    final table = _favoriteTable(folder);
    return _db.select("""
        SELECT MAX(display_order) AS max_value
        FROM $table;
      """).firstOrNull?["max_value"] ??
        0;
  }

  int minValue(String folder) {
    final table = _favoriteTable(folder);
    return _db.select("""
        SELECT MIN(display_order) AS min_value
        FROM $table;
      """).firstOrNull?["min_value"] ??
        0;
  }

  List<FavoriteItem> getFolderComics(String folder) {
    final table = _favoriteTable(folder);
    var rows = _db.select("""
        select * from $table
        ORDER BY display_order;
      """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  static Future<List<FavoriteItem>> _getFolderComicsAsync(
    String folder,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        var rows = db.select('''
          select * from ${_favoriteTable(folder)}
          ORDER BY display_order;
        ''');
        return rows.map((element) => FavoriteItem.fromRow(element)).toList();
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get the comics in the folder
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    _favoriteTable(folder);
    return _getFolderComicsAsync(folder, "${App.dataPath}/local_favorite.db");
  }

  List<FavoriteItem> getAllComics() {
    var res = <FavoriteItem>{};
    for (final folder in folderNames) {
      final table = _favoriteTable(folder);
      var comics = _db.select("""
        select * from $table;
      """);
      res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
    }
    return res.toList();
  }

  static Future<List<FavoriteItem>> _getAllComicsAsync(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        var res = <FavoriteItem>{};
        for (final folder in folders) {
          var comics = db.select('select * from ${_favoriteTable(folder)};');
          res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
        }
        return res.toList();
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get all the comics
  Future<List<FavoriteItem>> getAllComicsAsync() {
    return _getAllComicsAsync(folderNames, "${App.dataPath}/local_favorite.db");
  }

  void addTagTo(String folder, String id, String tag) {
    _db.execute(
      '''
      update ${_favoriteTable(folder)}
      set tags = ? || tags
      where id == ?
    ''',
      ['$tag,', id],
    );
    notifyListeners();
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    var res = <FavoriteItemWithFolderInfo>[];
    for (final folder in folderNames) {
      final table = _favoriteTable(folder);
      var comics = _db.select("""
        select * from $table;
      """);
      res.addAll(
        comics.map(
          (element) =>
              FavoriteItemWithFolderInfo(FavoriteItem.fromRow(element), folder),
        ),
      );
    }
    return res;
  }

  bool existsFolder(String name) {
    return folderNames.contains(name);
  }

  /// create a folder
  String createFolder(String name, [bool renameWhenInvalidName = false]) {
    if (name.isEmpty) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw "name is empty!";
      }
    }
    if (existsFolder(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    _favoriteTable(name);
    if (name == 'folder_order' || name == 'folder_sync') {
      throw const FormatException('Reserved favorite folder name');
    }
    if (name.length > 64) {
      throw const FormatException('Favorite folder name is too long');
    }
    final table = _favoriteTable(name);
    _db.execute("""
      create table $table(
        id text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        translated_tags TEXT,
        primary key (id, type)
      );
    """);
    notifyListeners();
    counts[name] = 0;
    return name;
  }

  void linkFolderToNetwork(String folder, String source, String networkFolder) {
    _db.execute(
      """
      insert or replace into folder_sync (folder_name, source_key, source_folder)
      values (?, ?, ?);
    """,
      [folder, source, networkFolder],
    );
  }

  bool isLinkedToNetworkFolder(
    String folder,
    String source,
    String networkFolder,
  ) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ? and source_key == ? and source_folder == ?;
    """,
      [folder, source, networkFolder],
    );
    return res.isNotEmpty;
  }

  (String?, String?) findLinked(String folder) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ?;
    """,
      [folder],
    );
    if (res.isEmpty) {
      return (null, null);
    }
    return (res.first["source_key"], res.first["source_folder"]);
  }

  bool comicExists(String folder, String id, ComicType type) {
    final table = _favoriteTable(folder);
    var res = _db.select(
      """
      select * from $table
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    return res.isNotEmpty;
  }

  FavoriteItem getComic(String folder, String id, ComicType type) {
    final table = _favoriteTable(folder);
    var res = _db.select(
      """
      select * from $table
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      throw Exception("Comic not found");
    }
    return FavoriteItem.fromRow(res.first);
  }

  String _translateTags(List<String> tags) {
    var res = <String>[];
    for (var tag in tags) {
      var translated = tag.translateTagsToCN;
      if (translated != tag) {
        res.add(translated);
      }
    }
    return res.join(",");
  }

  /// add comic to a folder.
  /// return true if success, false if already exists
  bool addComic(
    String folder,
    FavoriteItem comic, [
    int? order,
    String? updateTime,
  ]) {
    if (!existsFolder(folder)) {
      throw Exception("Folder does not exists");
    }
    final table = _favoriteTable(folder);
    var res = _db.select(
      """
      select * from $table
      where id == ? and type == ?;
    """,
      [comic.id, comic.type.value],
    );
    if (res.isNotEmpty) {
      return false;
    }
    var translatedTags = _translateTags(comic.tags);
    final params = [
      comic.id,
      comic.name,
      comic.author,
      comic.type.value,
      comic.tags.join(","),
      comic.coverPath,
      comic.time,
      translatedTags,
    ];
    if (order != null) {
      _db.execute(
        """
        insert into $table (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, order],
      );
    } else if (appdata.settings['newFavoriteAddTo'] == "end") {
      _db.execute(
        """
        insert into $table (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, maxValue(folder) + 1],
      );
    } else {
      _db.execute(
        """
        insert into $table (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, minValue(folder) - 1],
      );
    }
    if (updateTime != null) {
      var columns = _db.select("""
      pragma table_info($table);
    """);
      if (columns.any((element) => element["name"] == "last_update_time")) {
        _db.execute(
          """
          update $table
          set last_update_time = ?
          where id == ? and type == ?;
        """,
          [updateTime, comic.id, comic.type.value],
        );
      }
    }
    if (counts[folder] == null) {
      counts[folder] = count(folder);
    } else {
      counts[folder] = counts[folder]! + 1;
    }
    final identity = _identityKey(comic.id, comic.type.value);
    _hashedIds[identity] = (_hashedIds[identity] ?? 0) + 1;
    notifyListeners();
    return true;
  }

  void moveFavorite(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    var res = _db.select(
      """
    select * from "$targetFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    if (res.isNotEmpty) {
      return;
    }

    _db.execute(
      """
      insert into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
      select id, name, author, type, tags, cover_path, time, ?
      from "$sourceFolder"
      where id == ? and type == ?;
    """,
      [minValue(targetFolder) - 1, id, type.value],
    );

    _db.execute(
      """
    delete from "$sourceFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    notifyListeners();
  }

  void batchMoveFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        _db.execute(
          """
          delete from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Move Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    refreshHashedIds();

    notifyListeners();
  }

  void batchCopyFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Copy Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }

    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    refreshHashedIds();

    notifyListeners();
  }

  /// delete a folder
  void deleteFolder(String name) {
    final table = _favoriteTable(name);
    _db.execute("""
      drop table $table;
    """);
    _db.execute(
      """
      delete from folder_order
      where folder_name == ?;
    """,
      [name],
    );
    counts.remove(name);
    refreshHashedIds();
    notifyListeners();
  }

  void deleteComicWithId(String folder, String id, ComicType type) {
    final table = _favoriteTable(folder);
    LocalFavoriteImageProvider.delete(id, type.value);
    _db.execute(
      """
      delete from $table
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (counts[folder] != null) {
      counts[folder] = counts[folder]! - 1;
    } else {
      counts[folder] = count(folder);
    }
    reduceHashedId(id, type.value);
    notifyListeners();
  }

  void batchDeleteComics(String folder, List<FavoriteItem> comics) {
    final table = _favoriteTable(folder);
    _db.execute("BEGIN TRANSACTION");
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        _db.execute(
          """
          delete from $table
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
      }
      if (counts[folder] != null) {
        counts[folder] = counts[folder]! - comics.length;
      } else {
        counts[folder] = count(folder);
      }
    } catch (e) {
      Log.error("Batch Delete Comics", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    for (var comic in comics) {
      reduceHashedId(comic.id, comic.type.value);
    }
    notifyListeners();
  }

  void batchDeleteComicsInAllFolders(List<ComicID> comics) {
    _db.execute("BEGIN TRANSACTION");
    var folderNames = _getFolderNamesWithDB();
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        for (var folder in folderNames) {
          final table = _favoriteTable(folder);
          _db.execute(
            """
            delete from $table
            where id == ? and type == ?;
          """,
            [comic.id, comic.type.value],
          );
        }
      }
    } catch (e) {
      Log.error("Batch Delete Comics in All Folders", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    unawaited(initCounts());
    notifyListeners();
  }

  Future<int> removeInvalid() async {
    int count = 0;
    await Future.microtask(() {
      var all = allComics();
      for (var c in all) {
        var comicSource = c.type.comicSource;
        if ((c.type == ComicType.local &&
                LocalManager().find(c.id, c.type) == null) ||
            (c.type != ComicType.local && comicSource == null)) {
          deleteComicWithId(c.folder, c.id, c.type);
          count++;
        }
      }
    });
    return count;
  }

  Future<void> clearAll() async {
    close();
    File("${App.dataPath}/local_favorite.db").deleteSync();
    await init();
  }

  void reorder(List<FavoriteItem> newFolder, String folder) async {
    final table = _favoriteTable(folder);
    if (!existsFolder(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    _db.execute("BEGIN TRANSACTION");
    try {
      for (int i = 0; i < newFolder.length; i++) {
        _db.execute(
          """
          update $table
          set display_order = ?
          where id == ? and type == ?;
        """,
          [i, newFolder[i].id, newFolder[i].type.value],
        );
      }
    } catch (e) {
      Log.error("Reorder", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    notifyListeners();
  }

  void rename(String before, String after) {
    final beforeTable = _favoriteTable(before);
    final afterTable = _favoriteTable(after);
    if (existsFolder(after)) {
      throw "Name already exists!";
    }
    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute("""
        ALTER TABLE $beforeTable
        RENAME TO $afterTable;
      """);
      _db.execute(
        """
        update folder_order
        set folder_name = ?
        where folder_name == ?;
      """,
        [after, before],
      );
      _db.execute(
        """
        update folder_sync
        set folder_name = ?
        where folder_name == ?;
      """,
        [after, before],
      );
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    counts[after] = counts[before] ?? 0;
    counts.remove(before);
    notifyListeners();
  }

  void onRead(String id, ComicType type) async {
    if (appdata.settings['moveFavoriteAfterRead'] == "none") {
      markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = appdata.settings['followUpdatesFolder'];
    for (final folder in folderNames) {
      final table = _favoriteTable(folder);
      var rows = _db.select(
        """
        select * from $table
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        var newTime = DateTime.now()
            .toIso8601String()
            .replaceFirst("T", " ")
            .substring(0, 19);
        String updateLocationSql = "";
        if (appdata.settings['moveFavoriteAfterRead'] == "end") {
          int maxValue =
              _db.select("""
            SELECT MAX(display_order) AS max_value
            FROM $table;
          """).firstOrNull?["max_value"] ??
              0;
          updateLocationSql = "display_order = ${maxValue + 1},";
        } else if (appdata.settings['moveFavoriteAfterRead'] == "start") {
          int minValue =
              _db.select("""
            SELECT MIN(display_order) AS min_value
            FROM $table;
          """).firstOrNull?["min_value"] ??
              0;
          updateLocationSql = "display_order = ${minValue - 1},";
        }
        _db.execute(
          """
            UPDATE $table
            SET 
              $updateLocationSql
              ${followUpdatesFolder == folder ? "has_new_update = 0," : ""}
              time = ?
            WHERE id == ? and type == ?;
          """,
          [newTime, id, type.value],
        );
        if (followUpdatesFolder == folder) {
          updateFollowUpdatesUI();
        }
      }
    }
    notifyListeners();
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) {
    final table = _favoriteTable(folder);
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    keyword = "%$keyword%";
    var res = _db.select(
      """
      SELECT * FROM $table
      WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
    """,
      [keyword, keyword, keyword, keyword],
    );
    var comics = res.map((e) => FavoriteItem.fromRow(e)).toList();
    bool test(FavoriteItem comic, String keyword) {
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics = comics
          .where((element) => test(element, keywordList[i]))
          .toList();
    }
    return comics;
  }

  List<FavoriteItem> search(String keyword) {
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    var comics = <FavoriteItem>{};
    for (var table in folderNames) {
      keyword = "%$keyword%";
      var res = _db.select(
        """
        SELECT * FROM "$table" 
        WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
      """,
        [keyword, keyword, keyword, keyword],
      );
      for (var comic in res) {
        comics.add(FavoriteItem.fromRow(comic));
      }
      if (comics.length > 200) {
        break;
      }
    }

    bool test(FavoriteItem comic, String keyword) {
      keyword = keyword.trim();
      if (keyword.isEmpty) {
        return true;
      }
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    return comics.where((element) {
      for (var i = 1; i < keywordList.length; i++) {
        if (!test(element, keywordList[i])) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  void editTags(String id, String folder, List<String> tags) {
    final table = _favoriteTable(folder);
    _db.execute(
      """
        update $table
        set tags = ?
        where id == ?;
      """,
      [tags.join(","), id],
    );
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    for (final folder in folderNames) {
      final table = _favoriteTable(folder);
      if (_db.select(
        'SELECT 1 FROM $table WHERE id = ? AND type = ? LIMIT 1;',
        [id, type.value],
      ).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
    final table = _favoriteTable(folder);
    _db.execute(
      """
      update $table
      set name = ?, author = ?, cover_path = ?, tags = ?
      where id == ? and type == ?;
    """,
      [
        comic.name,
        comic.author,
        comic.coverPath,
        comic.tags.join(","),
        comic.id,
        comic.type.value,
      ],
    );
    if (notify) {
      notifyListeners();
    }
  }

  String folderToJson(String folder) {
    final table = _favoriteTable(folder);
    var res = _db.select("""
      select * from $table;
    """);
    return jsonEncode({
      "info": "Generated by Venera Prime",
      "name": folder,
      "comics": res.map((e) => FavoriteItem.fromRow(e).toJson()).toList(),
    });
  }

  void fromJson(String json) {
    var data = jsonDecode(json);
    if (data is! Map ||
        data['comics'] is! List ||
        data['comics'].length > 10000) {
      throw const FormatException('Invalid favorite data');
    }
    var folder = data["name"];
    if (folder == null || folder is! String) {
      throw "Invalid data";
    }
    if (existsFolder(folder)) {
      int i = 0;
      while (existsFolder("$folder($i)")) {
        i++;
      }
      folder = "$folder($i)";
    }
    createFolder(folder);
    for (var comic in data["comics"]) {
      try {
        addComic(folder, FavoriteItem.fromJson(comic));
      } catch (e) {
        Log.error("Import Data", e.toString());
      }
    }
  }

  void prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    final quotedTable = _favoriteTable(table);
    // check if the table has the column "last_update_time" "has_new_update" "last_check_time"
    var columns = _db.select("""
      pragma table_info($quotedTable);
    """);
    if (!columns.any((element) => element["name"] == "last_update_time")) {
      _db.execute("""
        alter table $quotedTable
        add column last_update_time TEXT;
      """);
    }
    if (!columns.any((element) => element["name"] == "has_new_update")) {
      _db.execute("""
        alter table $quotedTable
        add column has_new_update int;
      """);
    }
    if (clearData) {
      _db.execute("""
        update $quotedTable
        set has_new_update = 0;
      """);
    }
    if (!columns.any((element) => element["name"] == "last_check_time")) {
      _db.execute("""
        alter table $quotedTable
        add column last_check_time int;
      """);
    }
  }

  void updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime, {
    bool markNewUpdate = true,
  }) {
    final table = _favoriteTable(folder);
    var oldTime = _db
        .select(
          """
      select last_update_time from $table
      where id == ? and type == ?;
    """,
          [id, type.value],
        )
        .first['last_update_time'];
    var hasNewUpdate = markNewUpdate && oldTime != updateTime;
    _db.execute(
      """
      update $table
      set last_update_time = ?, has_new_update = ?, last_check_time = ?
      where id == ? and type == ?;
    """,
      [
        updateTime,
        hasNewUpdate ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
        id,
        type.value,
      ],
    );
  }

  void updateCheckTime(String folder, String id, ComicType type) {
    final table = _favoriteTable(folder);
    _db.execute(
      """
      update $table
      set last_check_time = ?
      where id == ? and type == ?;
    """,
      [DateTime.now().millisecondsSinceEpoch, id, type.value],
    );
  }

  int countUpdates(String folder) {
    final table = _favoriteTable(folder);
    return _db.select("""
      select count(*) as c from $table
      where has_new_update == 1;
    """).first['c'];
  }

  List<FavoriteItemWithUpdateInfo> getUpdates(String folder) {
    final table = _favoriteTable(folder);
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from $table
      where has_new_update == 1;
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    final table = _favoriteTable(folder);
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from $table;
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  void markAsRead(String id, ComicType type) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || folder.isEmpty || !existsFolder(folder)) {
      return;
    }
    final table = _favoriteTable(folder);
    _db.execute(
      """
      update $table
      set has_new_update = 0
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
  }

  void close() {
    if (!isInitialized) return;
    _db.dispose();
    isInitialized = false;
    counts = {};
    _hashedIds = {};
    _initializing = null;
  }

  void notifyChanges() {
    notifyListeners();
  }
}
