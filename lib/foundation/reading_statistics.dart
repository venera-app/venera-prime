import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

String formatReadingDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
}

class ReadingStatistic {
  final String day;
  final String comicId;
  final ComicType comicType;
  final String title;
  final String author;
  final String cover;
  final int durationSeconds;
  final DateTime lastReadAt;

  const ReadingStatistic({
    required this.day,
    required this.comicId,
    required this.comicType,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationSeconds,
    required this.lastReadAt,
  });

  ReadingStatistic.fromRow(Row row)
    : day = row['day'] as String,
      comicId = row['comic_id'] as String,
      comicType = ComicType(row['comic_type'] as int),
      title = row['title'] as String,
      author = row['author'] as String,
      cover = row['cover'] as String,
      durationSeconds = row['duration_seconds'] as int,
      lastReadAt = DateTime.fromMillisecondsSinceEpoch(
        row['last_read_at'] as int,
      );
}

class ReadingStatisticsManager with ChangeNotifier {
  static ReadingStatisticsManager? _instance;
  ReadingStatisticsManager._();
  factory ReadingStatisticsManager() =>
      _instance ??= ReadingStatisticsManager._();

  late Database _db;
  bool isInitialized = false;
  Future<void>? _initializing;

  Future<void> init() => _initializing ??= _initWithReset();

  Future<void> _initWithReset() async {
    try {
      await _initInternal();
    } catch (_) {
      _initializing = null;
      isInitialized = false;
      try {
        _db.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _initInternal() async {
    if (isInitialized) return;
    final dbPath = FilePath.join(App.dataPath, 'reading_statistics.db');
    try {
      _db = sqlite3.open(dbPath);
      final integrity = _db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first[0] != 'ok') {
        throw StateError('reading statistics database integrity check failed');
      }
      _createTable();
    } catch (e, s) {
      Log.error('ReadingStatistics', 'Database reset after failure: $e', s);
      try {
        _db.dispose();
      } catch (_) {}
      final old = File(dbPath);
      if (old.existsSync()) {
        await old.rename(
          '$dbPath.corrupt.${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      _db = sqlite3.open(dbPath);
      _createTable();
    }
    isInitialized = true;
    notifyListeners();
  }

  void _createTable() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS reading_statistics (
        day TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        cover TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL DEFAULT 0,
        last_read_at INTEGER NOT NULL,
        PRIMARY KEY (day, comic_id, comic_type)
      );
    ''');
  }

  void recordSession({
    required Comic comic,
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    if (!isInitialized || !endedAt.isAfter(startedAt)) return;
    final type = _typeForComic(comic);
    var cursor = startedAt;
    while (cursor.isBefore(endedAt)) {
      final nextDay = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final end = endedAt.isBefore(nextDay) ? endedAt : nextDay;
      final seconds = end.difference(cursor).inSeconds;
      if (seconds > 0) {
        final day = _day(cursor);
        _db.execute(
          '''
          INSERT INTO reading_statistics
            (day, comic_id, comic_type, title, author, cover,
             duration_seconds, last_read_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(day, comic_id, comic_type) DO UPDATE SET
            title = excluded.title,
            author = excluded.author,
            cover = excluded.cover,
            duration_seconds = duration_seconds + excluded.duration_seconds,
            last_read_at = MAX(last_read_at, excluded.last_read_at);
        ''',
          [
            day,
            comic.id,
            type.value,
            comic.title,
            comic.subtitle ?? '',
            comic.cover,
            seconds,
            end.millisecondsSinceEpoch,
          ],
        );
      }
      cursor = end;
    }
    Future.microtask(notifyListeners);
  }

  static String _day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static ComicType _typeForComic(Comic comic) {
    if (comic.sourceKey == 'local') return ComicType.local;
    if (comic.sourceKey.startsWith('Unknown:')) {
      return ComicType(int.tryParse(comic.sourceKey.substring(8)) ?? 0);
    }
    return ComicType.fromKey(comic.sourceKey);
  }

  int durationForDay(DateTime day) {
    final row = _db.select(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS value FROM reading_statistics WHERE day = ?;',
      [_day(day)],
    ).first;
    return row['value'] as int;
  }

  int totalDuration() =>
      (_db
              .select(
                'SELECT COALESCE(SUM(duration_seconds), 0) AS value FROM reading_statistics;',
              )
              .first['value']
          as int);

  List<ReadingStatistic> recent({int days = 30}) {
    final from = DateTime.now().subtract(Duration(days: days - 1));
    return _db
        .select(
          '''
      SELECT * FROM reading_statistics WHERE day >= ?
      ORDER BY last_read_at DESC;
    ''',
          [_day(from)],
        )
        .map(ReadingStatistic.fromRow)
        .toList();
  }

  void close() {
    if (!isInitialized) return;
    _db.dispose();
    isInitialized = false;
    _initializing = null;
  }
}
