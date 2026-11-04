import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"],
      subtitle = row["subtitle"],
      cover = row["cover"],
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String)
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  bool matchesQuery(String query) {
    final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final text = [
      title,
      subtitle,
      id,
      sourceKey,
      type.comicSource?.name ?? '',
    ].join('\n').toLowerCase();
    return words.every(text.contains);
  }

  String get lastReadTime {
    final local = time.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}';
  }

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res.isEmpty ? lastReadTime : '$res\n$lastReadTime';
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;
  Future<void>? _initializing;

  String _cacheKey(String id, HistoryType type) => "${type.value}:$id";

  Future<void> init() => _initializing ??= _initWithReset();

  Future<void> _initWithReset() async {
    try {
      await _initInternal();
    } catch (_) {
      _initializing = null;
      isInitialized = false;
      _cachedHistoryIds = null;
      cachedHistories.clear();
      try {
        _db.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _initInternal() async {
    if (isInitialized) return;
    final dbPath = "${App.dataPath}/history.db";
    try {
      _db = sqlite3.open(dbPath);
      final integrity = _db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first[0] != 'ok') {
        throw StateError('history database integrity check failed');
      }
      _db.execute("""
        create table if not exists history  (
          id text not null,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      """);
    } catch (e, s) {
      Log.error(
        'History',
        'Database is corrupt; preserving it and creating a new one: $e',
        s,
      );
      try {
        _db.dispose();
      } catch (_) {}
      final backup = File(
        '$dbPath.corrupt.${DateTime.now().millisecondsSinceEpoch}',
      );
      File(dbPath).renameSync(backup.path);
      _db = sqlite3.open(dbPath);
      _db.execute("""
        create table history (
          id text not null, title text, subtitle text, cover text,
          time int, type int, ep int, page int, readEpisode text,
          max_page int, chapter_group int, primary key (id, type)
        );
      """);
    }

    var columns = _db.select("PRAGMA table_info(history);");
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      _db.execute("alter table history add column chapter_group int;");
    }
    final hasSingleIdPrimaryKey =
        columns.any(
          (element) => element['name'] == 'id' && element['pk'] == 1,
        ) &&
        !columns.any(
          (element) => element['name'] == 'type' && element['pk'] == 2,
        );
    if (hasSingleIdPrimaryKey) {
      _db.execute('BEGIN;');
      try {
        _db.execute('''
          CREATE TABLE history_migrated (
            id TEXT NOT NULL, title TEXT, subtitle TEXT, cover TEXT,
            time INT, type INT, ep INT, page INT, readEpisode TEXT,
            max_page INT, chapter_group INT, PRIMARY KEY (id, type)
          );
        ''');
        _db.execute('''
          INSERT OR REPLACE INTO history_migrated
          SELECT id, title, subtitle, cover, time, type, ep, page,
                 readEpisode, max_page, chapter_group FROM history;
        ''');
        _db.execute('DROP TABLE history;');
        _db.execute('ALTER TABLE history_migrated RENAME TO history;');
        _db.execute('COMMIT;');
      } catch (_) {
        _db.execute('ROLLBACK;');
        rethrow;
      }
    }

    notifyListeners();
    ImageFavoriteManager().init();
    isInitialized = true;
  }

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  /// Native sqlite handles must stay in their owning isolate.
  Future<void> addHistoryAsync(History newItem) async {
    addHistory(newItem);
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKey(newItem.id, newItem.type)] = true;
    }
    cachedHistories[_cacheKey(newItem.id, newItem.type)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
    DataSync.instance?.onDataChanged();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
    DataSync.instance?.onDataChanged();
  }

  void remove(String id, ComicType type) async {
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
    DataSync.instance?.onDataChanged();
  }

  void updateCache() {
    _cachedHistoryIds = {};
    var res = _db.select("""
        select id, type from history;
      """);
    for (var element in res) {
      _cachedHistoryIds![_cacheKey(
            element["id"] as String,
            ComicType(element["type"] as int),
          )] =
          true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    var cacheKey = _cacheKey(id, type);
    if (!_cachedHistoryIds!.containsKey(cacheKey)) {
      return null;
    }
    if (cachedHistories.containsKey(cacheKey)) {
      return cachedHistories[cacheKey];
    }

    var res = _db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  void close() {
    if (!isInitialized) return;
    isInitialized = false;
    _db.dispose();
    _cachedHistoryIds = null;
    cachedHistories.clear();
    _initializing = null;
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
    DataSync.instance?.onDataChanged();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(
    History history, {
    bool Function()? isCancelled,
    void Function(String reason)? onError,
  }) async {
    if (history.type == ComicType.local) return false;
    return _refreshSingleHistory(
      history,
      isCancelled: isCancelled,
      onError: onError,
    );
  }

  Future<bool> _refreshSingleHistory(
    History history, {
    bool Function()? isCancelled,
    void Function(String reason)? onError,
  }) async {
    if (isCancelled?.call() == true) return false;
    final source = history.type.comicSource;
    if (source?.loadComicInfo == null) {
      onError?.call('Comic source is unavailable');
      return false;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (isCancelled?.call() == true) return false;
      try {
        final details = (await source!.loadComicInfo!(history.id)).data;
        if (isCancelled?.call() == true) return false;
        // Keep reading progress changed while this background request was
        // running, and never recreate a history the user has just removed.
        final current = find(history.id, history.type);
        if (current == null) return true;
        final updated = History.fromMap({
          'type': current.type.value,
          'time': current.time.millisecondsSinceEpoch,
          'title': details.title,
          'subtitle': details.subTitle ?? '',
          'cover': details.cover,
          'ep': current.ep,
          'page': current.page,
          'id': current.id,
          'readEpisode': current.readEpisode.toList(),
          'max_page': current.maxPage,
        });
        updated.group = current.group;
        addHistory(updated);
        return true;
      } catch (error, stack) {
        if (isCancelled?.call() == true) return false;
        Log.error(
          'History',
          'Exception while refreshing history info: $error',
          stack,
        );
        if (attempt == 2) {
          onError?.call(error.toString());
          return false;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  /// The producer and its workers observe cancellation, independently of the
  /// view displaying progress. Cancelling the stream also stops new requests.
  Stream<RefreshProgress> refreshAllHistoriesStream({
    bool Function()? isCancelled,
    void Function(History history, String reason)? onError,
  }) {
    var subscriptionCancelled = false;
    final controller = StreamController<RefreshProgress>(
      onCancel: () => subscriptionCancelled = true,
    );
    bool cancelled() => subscriptionCancelled || isCancelled?.call() == true;
    _refreshAllHistoriesBase(controller, cancelled, onError).then(
      (_) {
        controller.close();
      },
      onError: (Object error, StackTrace stack) {
        if (!subscriptionCancelled) controller.addError(error, stack);
        controller.close();
      },
    );
    return controller.stream;
  }

  Future<void> _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
    bool Function() isCancelled,
    void Function(History history, String reason)? onError,
  ) async {
    final histories = getAll();
    final remote = histories.where((h) => h.type != ComicType.local).toList();
    final skipped = histories.length - remote.length;
    var current = 0;
    var success = 0;
    var failed = 0;
    void report() {
      if (!isCancelled()) {
        controller.add(
          RefreshProgress(remote.length, current, success, failed, skipped),
        );
      }
    }

    report();
    final channel = Channel<History>(10);
    final producer = () async {
      try {
        var count = 0;
        for (final history in remote) {
          if (isCancelled()) break;
          await channel.push(history);
          count++;
          if (count % 5 == 0 && count < remote.length && !isCancelled()) {
            // Retain the existing source rate limit: five submissions at a
            // time, then a delay capped at ten seconds.
            final delay = (count % 100 + 1).clamp(1, 10);
            await Future<void>.delayed(Duration(seconds: delay));
          }
        }
      } finally {
        channel.close();
      }
    }();
    await Future.wait(
      List.generate(5, (_) async {
        while (true) {
          final history = await channel.pop();
          if (history == null) break;
          // Drain the bounded queue when cancelled so the producer cannot stay
          // blocked in push() after all workers stop making requests.
          if (isCancelled()) continue;
          final ok = await _refreshSingleHistory(
            history,
            isCancelled: isCancelled,
            onError: (reason) => onError?.call(history, reason),
          );
          if (isCancelled()) continue;
          current++;
          if (ok) {
            success++;
          } else {
            failed++;
          }
          report();
        }
      }),
    );
    await producer;
    notifyListeners();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
