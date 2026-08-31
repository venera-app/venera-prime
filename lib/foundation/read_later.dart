import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

class ReadLaterComic implements Comic {
  @override
  final String id;
  @override
  final String title;
  @override
  final String subtitle;
  @override
  final List<String> tags;
  @override
  final String cover;
  @override
  final String description;
  @override
  final String sourceKey;
  final ComicType type;

  ReadLaterComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.cover,
    required this.description,
    required this.sourceKey,
    required this.type,
  });

  ReadLaterComic.fromRow(Row row)
    : id = row['id'] as String,
      title = row['title'] as String,
      subtitle = row['subtitle'] as String,
      tags = List<String>.from(jsonDecode(row['tags'] as String)),
      cover = row['cover'] as String,
      description = row['description'] as String? ?? '',
      sourceKey = row['source_key'] as String,
      type = ComicType(row['comic_type'] as int);

  @override
  int? get maxPage => null;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'tags': tags,
    'cover': cover,
    'description': description,
    'sourceKey': sourceKey,
    'comicType': type.value,
  };
}

class ReadLaterManager with ChangeNotifier {
  static ReadLaterManager? _instance;
  ReadLaterManager._();
  factory ReadLaterManager() => _instance ??= ReadLaterManager._();

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
    final dbPath = FilePath.join(App.dataPath, 'read_later.db');
    try {
      _db = sqlite3.open(dbPath);
      final integrity = _db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first[0] != 'ok') {
        throw StateError('read later database integrity check failed');
      }
      _createTable();
      _migrateSchema();
    } catch (e, s) {
      Log.error(
        'ReadLater',
        'Database is corrupt; preserving it and creating a new one: $e',
        s,
      );
      try {
        _db.dispose();
      } catch (_) {}
      final backup = File(
        '$dbPath.corrupt.${DateTime.now().millisecondsSinceEpoch}',
      );
      final old = File(dbPath);
      if (old.existsSync()) await old.rename(backup.path);
      _db = sqlite3.open(dbPath);
      _createTable();
    }
    isInitialized = true;
    notifyListeners();
  }

  void _createTable() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS read_later (
        id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        source_key TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (id, comic_type)
      );
    ''');
  }

  void _migrateSchema() {
    final columns = _db.select('PRAGMA table_info(read_later);');
    if (!columns.any((row) => row['name'] == 'description')) {
      _db.execute(
        "ALTER TABLE read_later ADD COLUMN description TEXT NOT NULL DEFAULT '';",
      );
    }
  }

  List<ReadLaterComic> getAll({String keyword = ''}) {
    final rows = keyword.trim().isEmpty
        ? _db.select('SELECT * FROM read_later ORDER BY added_at DESC;')
        : _db.select(
            '''SELECT * FROM read_later
               WHERE title LIKE ? OR subtitle LIKE ? OR tags LIKE ?
               ORDER BY added_at DESC;''',
            ['%$keyword%', '%$keyword%', '%$keyword%'],
          );
    return rows.map(ReadLaterComic.fromRow).toList();
  }

  bool contains(String id, ComicType type) {
    return _db.select(
      'SELECT 1 FROM read_later WHERE id = ? AND comic_type = ? LIMIT 1;',
      [id, type.value],
    ).isNotEmpty;
  }

  ComicType typeForComic(Comic comic) {
    if (comic.sourceKey == 'local') return ComicType.local;
    if (comic.sourceKey.startsWith('Unknown:')) {
      final value = int.tryParse(comic.sourceKey.substring('Unknown:'.length));
      if (value != null) return ComicType(value);
    }
    return ComicType.fromKey(comic.sourceKey);
  }

  bool containsComic(Comic comic) => contains(comic.id, typeForComic(comic));

  bool add(Comic comic) {
    final type = typeForComic(comic);
    if (contains(comic.id, type)) return false;
    _db.execute(
      '''INSERT INTO read_later
         (id, comic_type, source_key, title, subtitle, description, tags, cover, added_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);''',
      [
        comic.id,
        type.value,
        comic.sourceKey,
        comic.title,
        comic.subtitle ?? '',
        comic.description,
        jsonEncode(comic.tags ?? const <String>[]),
        comic.cover,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
    return true;
  }

  void restore(Iterable<ReadLaterComic> comics) {
    final values = comics.toList();
    if (values.isEmpty) return;
    for (final comic in values) {
      _db.execute(
        '''INSERT OR REPLACE INTO read_later
           (id, comic_type, source_key, title, subtitle, description, tags, cover, added_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);''',
        [
          comic.id,
          comic.type.value,
          comic.sourceKey,
          comic.title,
          comic.subtitle,
          comic.description,
          jsonEncode(comic.tags),
          comic.cover,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }
    notifyListeners();
  }

  bool remove(String id, ComicType type) {
    _db.execute('DELETE FROM read_later WHERE id = ? AND comic_type = ?;', [
      id,
      type.value,
    ]);
    final changed = (_db.select('SELECT changes();').first[0] as int) > 0;
    if (changed) notifyListeners();
    return changed;
  }

  bool removeComic(Comic comic) => remove(comic.id, typeForComic(comic));

  bool toggle(Comic comic) =>
      containsComic(comic) ? removeComic(comic) : add(comic);

  void removeMany(Iterable<ReadLaterComic> comics) {
    final values = comics.toList();
    if (values.isEmpty) return;
    _db.execute('BEGIN;');
    try {
      for (final comic in values) {
        _db.execute('DELETE FROM read_later WHERE id = ? AND comic_type = ?;', [
          comic.id,
          comic.type.value,
        ]);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    notifyListeners();
  }

  void clear() {
    _db.execute('DELETE FROM read_later;');
    notifyListeners();
  }

  void close() {
    if (!isInitialized) return;
    _db.dispose();
    isInitialized = false;
    _initializing = null;
  }
}
