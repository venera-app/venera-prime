import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path_utils;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/natural_sort.dart';
import 'package:venera/utils/atomic_file.dart';

import 'app.dart';
import 'history.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  /// Optional description imported from local archive metadata.
  final String descriptionText;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  /// Whether deleting this record is allowed to remove its files.
  final bool managedByApp;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    this.descriptionText = '',
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
    this.managedByApp = true,
  });

  LocalComic.fromRow(Row row)
    : id = row['id'] as String,
      title = row['title'] as String,
      subtitle = row['subtitle'] as String,
      descriptionText = row['description'] as String? ?? '',
      tags = List.from(jsonDecode(row['tags'] as String)),
      directory = row['directory'] as String,
      chapters = ComicChapters.fromJsonOrNull(
        jsonDecode(row['chapters'] as String),
      ),
      cover = row['cover'] as String,
      comicType = ComicType(row['comic_type'] as int),
      downloadedChapters = List.from(
        jsonDecode(row['downloadedChapters'] as String),
      ),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      managedByApp = (row['managed_by_app'] as int? ?? 1) != 0;

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  bool get isMissing => !Directory(baseDir).existsSync();

  @override
  String get description => descriptionText;

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class _LocalMetadata {
  final String? title;
  final String? author;
  final String? description;
  final List<String>? tags;

  const _LocalMetadata({this.title, this.author, this.description, this.tags});
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  bool isInitialized = false;
  Future<void>? _initializing;

  /// path to the directory where all the comics are stored
  late String path;

  bool _changingPath = false;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    if (_changingPath) {
      return "Storage path change already in progress";
    }
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    final sourcePath = path_utils.canonicalize(path);
    final destinationPath = path_utils.canonicalize(newPath);
    if (sourcePath == destinationPath) {
      return null;
    }
    if (path_utils.isWithin(sourcePath, destinationPath)) {
      return "New storage path cannot be inside the current storage path";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    _changingPath = true;
    try {
      await copyDirectoryIsolate(directory, newDir);
      await atomicWriteString(
        File(FilePath.join(App.dataPath, 'local_path')),
        newPath,
      );
      await directory.deleteContents(recursive: true);
      path = newPath;
      _checkNoMedia();
      return null;
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    } finally {
      _changingPath = false;
    }
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
      await _persistPath();
    }
  }

  Future<void> _persistPath() async {
    await atomicWriteString(
      File(FilePath.join(App.dataPath, 'local_path')),
      path,
    );
  }

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
    final dbPath = '${App.dataPath}/local.db';
    try {
      _db = sqlite3.open(dbPath);
      final integrity = _db.select('PRAGMA integrity_check;');
      if (integrity.isEmpty || integrity.first[0] != 'ok') {
        throw StateError('local database integrity check failed');
      }
      _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
          downloadedChapters TEXT NOT NULL,
          created_at INTEGER,
          managed_by_app INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY (id, comic_type)
      );
    ''');
    } catch (e, s) {
      Log.error(
        'Local',
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
      _db.execute('''
        CREATE TABLE comics (
          id TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          tags TEXT NOT NULL, directory TEXT NOT NULL, chapters TEXT NOT NULL,
          cover TEXT NOT NULL, comic_type INTEGER NOT NULL,
          downloadedChapters TEXT NOT NULL, created_at INTEGER,
          managed_by_app INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY (id, comic_type)
        );
      ''');
    }
    final columns = _db.select('PRAGMA table_info(comics);');
    if (!columns.any((row) => row['name'] == 'description')) {
      _db.execute(
        "ALTER TABLE comics ADD COLUMN description TEXT NOT NULL DEFAULT '';",
      );
    }
    if (!columns.any((row) => row['name'] == 'managed_by_app')) {
      _db.execute(
        'ALTER TABLE comics ADD COLUMN managed_by_app INTEGER NOT NULL DEFAULT 1;',
      );
    }
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      final pathFile = File(FilePath.join(App.dataPath, 'local_path'));
      path = pathFile.readAsStringSync().trim();
      if (path.isEmpty || !directory.existsSync()) {
        path = await findDefaultPath();
        await _persistPath();
      }
    } else {
      path = await findDefaultPath();
      await _persistPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    await _checkPathValidation();
    _checkNoMedia();
    // Download task metadata references source definitions, but it is not
    // required to render the first frame. Restore it once sources are ready.
    unawaited(
      ComicSourceManager().ensureInit().then((_) {
        restoreDownloadingTasks();
      }),
    );
    isInitialized = true;
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    // A resumed task may report chapters already present in the database.
    // Merge idempotently so retries never duplicate chapter identifiers.
    var downloaded = <String>{...comic.downloadedChapters};
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      '''INSERT OR REPLACE INTO comics
         (id, title, subtitle, description, tags, directory, chapters, cover,
          comic_type, downloadedChapters, created_at, managed_by_app)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);''',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        comic.description,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded.toList()),
        comic.createdAt.millisecondsSinceEpoch,
        comic.managedByApp ? 1 : 0,
      ],
    );
    notifyListeners();
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    var res = _db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    close();
  }

  void close() {
    if (!isInitialized) return;
    _db.dispose();
    isInitialized = false;
    _initializing = null;
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<LocalRefreshResult> refresh({bool Function()? isCanceled}) async {
    final root = Directory(path);
    if (!await root.exists()) {
      return const LocalRefreshResult(0, 0, 0, true);
    }
    var discovered = 0;
    var updated = 0;
    var missing = 0;
    final known = <String, LocalComic>{
      for (final comic in getComics(LocalSortType.timeDesc))
        path_utils.canonicalize(comic.baseDir): comic,
    };
    await for (final entity in root.list()) {
      if (isCanceled?.call() == true) {
        return LocalRefreshResult(discovered, updated, missing, true);
      }
      if (entity is! Directory ||
          FileSystemEntity.typeSync(entity.path, followLinks: false) ==
              FileSystemEntityType.link) {
        continue;
      }
      final canonical = path_utils.canonicalize(entity.path);
      final existing = known[canonical];
      final imageFiles = await _imageFiles(entity);
      final chapterDirs = <Directory>[];
      await for (final child in entity.list()) {
        if (child is Directory &&
            FileSystemEntity.typeSync(child.path, followLinks: false) !=
                FileSystemEntityType.link &&
            (await _imageFiles(child)).isNotEmpty) {
          chapterDirs.add(child);
        }
      }
      chapterDirs.sort((a, b) => naturalCompare(a.name, b.name));
      final metadata = await _readLocalMetadata(entity);
      if (existing != null) {
        updated++;
        final cover = await _findCover(entity, imageFiles, chapterDirs);
        final refreshedChapters = _chaptersFromDisk(existing, chapterDirs);
        var title = metadata?.title ?? existing.title;
        if (title != existing.title) {
          final duplicate = findByName(title);
          if (duplicate != null && duplicate.id != existing.id) {
            title = existing.title;
          }
        }
        final refreshed = LocalComic(
          id: existing.id,
          title: title,
          subtitle: metadata?.author ?? existing.subtitle,
          descriptionText: metadata?.description ?? existing.descriptionText,
          tags: metadata?.tags ?? existing.tags,
          directory: existing.directory,
          chapters: refreshedChapters ?? existing.chapters,
          cover: cover ?? existing.cover,
          comicType: existing.comicType,
          downloadedChapters: _downloadedChapterIds(
            refreshedChapters ?? existing.chapters,
            chapterDirs,
          ),
          createdAt: existing.createdAt,
          managedByApp: existing.managedByApp,
        );
        if (!_sameLocalMetadata(existing, refreshed)) {
          await add(refreshed);
        }
        continue;
      }
      if (imageFiles.isEmpty && chapterDirs.isEmpty) continue;
      final cover = await _findCover(entity, imageFiles, chapterDirs);
      if (cover == null) continue;
      final chapters = chapterDirs.isEmpty
          ? null
          : ComicChapters({
              for (final chapter in chapterDirs) chapter.name: chapter.name,
            });
      final comic = LocalComic(
        id: findValidId(ComicType.local),
        title: metadata?.title ?? entity.name,
        subtitle: metadata?.author ?? '',
        descriptionText: metadata?.description ?? '',
        tags: metadata?.tags ?? const [],
        directory: entity.name,
        chapters: chapters,
        cover: cover,
        comicType: ComicType.local,
        downloadedChapters: chapters?.ids.toList() ?? const [],
        createdAt: (await entity.stat()).modified,
      );
      await add(comic);
      discovered++;
    }
    for (final comic in known.values) {
      if (comic.isMissing) missing++;
    }
    notifyListeners();
    return LocalRefreshResult(discovered, updated, missing, false);
  }

  Future<_LocalMetadata?> _readLocalMetadata(Directory directory) async {
    final jsonFile = File(FilePath.join(directory.path, 'metadata.json'));
    if (await jsonFile.exists()) {
      try {
        final decoded = jsonDecode(await jsonFile.readAsString());
        if (decoded is Map) {
          String? text(String key) {
            final value = decoded[key];
            if (value is! String || value.length > 1024 * 1024) return null;
            final trimmed = value.trim();
            return trimmed.isEmpty ? null : trimmed;
          }

          final rawTags = decoded['tags'];
          List<String>? tags;
          if (rawTags is List && rawTags.length <= 256) {
            final values = rawTags.whereType<String>().toList();
            if (values.length == rawTags.length &&
                values.every((value) => value.length <= 1024)) {
              tags = values;
            }
          } else if (rawTags is String && rawTags.length <= 64 * 1024) {
            tags = rawTags
                .split(RegExp(r'[,;|]'))
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .take(256)
                .toList();
          }
          return _LocalMetadata(
            title: text('title') ?? text('Title'),
            author: text('author') ?? text('Author'),
            description: text('description') ?? text('summary'),
            tags: tags,
          );
        }
      } catch (_) {}
    }

    final xmlFile = File(FilePath.join(directory.path, 'ComicInfo.xml'));
    if (await xmlFile.exists()) {
      try {
        final document = XmlDocument.parse(await xmlFile.readAsString());
        String read(String name) {
          return document.descendants
              .whereType<XmlElement>()
              .where((element) => element.localName == name)
              .map((element) => element.innerText.trim())
              .where((value) => value.isNotEmpty)
              .join(', ');
        }

        String? nullableText(String value) => value.isEmpty ? null : value;
        final genres = read('Genre')
            .split(RegExp(r'[,;]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .take(256)
            .toList();
        return _LocalMetadata(
          title: nullableText(read('Title')),
          author:
              (nullableText(read('Writer')) ?? nullableText(read('Penciller'))),
          description: nullableText(read('Summary')),
          tags: genres,
        );
      } catch (_) {}
    }
    return null;
  }

  ComicChapters? _chaptersFromDisk(
    LocalComic existing,
    List<Directory> chapterDirs,
  ) {
    if (chapterDirs.isEmpty) return existing.chapters;
    final diskNames = chapterDirs.map((directory) => directory.name).toSet();
    final chapters = <String, String>{};
    final existingChapters = existing.chapters?.allChapters ?? const {};
    if (existing.comicType != ComicType.local) {
      // Network downloads may only contain a subset of the source chapters.
      // Keep the source metadata and add any chapter directories introduced
      // by an older export or a manual filesystem change.
      chapters.addAll(existingChapters);
    } else {
      for (final entry in existingChapters.entries) {
        final directoryName = getChapterDirectoryName(entry.key);
        if (diskNames.contains(entry.key) ||
            diskNames.contains(directoryName)) {
          chapters[entry.key] = entry.value;
        }
      }
    }
    for (final directory in chapterDirs) {
      if (!chapters.keys.any(
        (id) => getChapterDirectoryName(id) == directory.name,
      )) {
        chapters[directory.name] = directory.name;
      }
    }
    return chapters.isEmpty ? null : ComicChapters(chapters);
  }

  List<String> _downloadedChapterIds(
    ComicChapters? chapters,
    List<Directory> chapterDirs,
  ) {
    if (chapters == null || chapterDirs.isEmpty) return const [];
    final existingIds = chapters.allChapters.keys.toList();
    return chapterDirs
        .map((directory) {
          return existingIds.firstWhere(
            (id) =>
                id == directory.name ||
                getChapterDirectoryName(id) == directory.name,
            orElse: () => directory.name,
          );
        })
        .toSet()
        .toList();
  }

  bool _sameLocalMetadata(LocalComic a, LocalComic b) {
    return a.title == b.title &&
        a.subtitle == b.subtitle &&
        a.descriptionText == b.descriptionText &&
        a.cover == b.cover &&
        _sameList(a.tags, b.tags) &&
        _sameList(a.downloadedChapters, b.downloadedChapters) &&
        jsonEncode(a.chapters?.toJson()) == jsonEncode(b.chapters?.toJson());
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<List<File>> _imageFiles(
    Directory directory, {
    bool includeCover = false,
  }) async {
    const extensions = {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'jpe',
      'avif',
      'bmp',
    };
    final files = <File>[];
    if (!await directory.exists()) return files;
    await for (final entity in directory.list()) {
      if (entity is File &&
          extensions.contains(entity.extension.toLowerCase()) &&
          (includeCover || !entity.name.toLowerCase().startsWith('cover.'))) {
        files.add(entity);
      }
    }
    files.sort((a, b) => naturalCompare(a.name, b.name));
    return files;
  }

  Future<String?> _findCover(
    Directory root,
    List<File> rootImages,
    List<Directory> chapterDirs,
  ) async {
    final cover = await _imageFiles(root, includeCover: true);
    File? preferred;
    for (final file in cover) {
      if (file.basenameWithoutExt.toLowerCase() == 'cover') {
        preferred = file;
        break;
      }
    }
    if (preferred != null) return preferred.name;
    if (rootImages.isNotEmpty) return rootImages.first.name;
    if (chapterDirs.isNotEmpty) {
      final images = await _imageFiles(chapterDirs.first);
      if (images.isNotEmpty) {
        return FilePath.join(chapterDirs.first.name, images.first.name);
      }
    }
    return null;
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.toLowerCase().startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        // Ignore metadata and unrelated files; passing them to the image
        // decoder can crash when a local comic folder contains extra files.
        const imageExtensions = {
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'jpe',
          'avif',
          'bmp',
        };
        if (!imageExtensions.contains(entity.extension.toLowerCase())) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) => naturalCompare(a.name, b.name));
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            descriptionText: comic.descriptionText,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
            managedByApp: comic.managedByApp,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir));
  }

  void completeTask(DownloadTask task) {
    add(task.toLocalComic());
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.firstOrNull?.resume();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
    }
  }

  Future<void> saveCurrentDownloadingTasks() async {
    var tasks = downloadingTasks.map((e) => e.toJson()).toList();
    await atomicWriteString(
      File(FilePath.join(App.dataPath, 'downloading_tasks.json')),
      jsonEncode(tasks),
    );
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        if (tasks is! Iterable) {
          throw const FormatException('Invalid task list');
        }
        for (var e in tasks) {
          if (e is! Map<String, dynamic>) continue;
          try {
            var task = DownloadTask.fromJson(e);
            if (task != null) downloadingTasks.add(task);
          } catch (taskError, taskStack) {
            Log.error(
              "LocalManager",
              "Failed to restore one download task: $taskError",
              taskStack,
            );
          }
        }
      } catch (e) {
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  void addTask(DownloadTask task) {
    if (downloadingTasks.contains(task)) {
      return;
    }
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    downloadingTasks.first.resume();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk && c.managedByApp && _isManagedPath(c.baseDir)) {
      _deleteDirectories([Directory(c.baseDir)]);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      var dir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (c.managedByApp &&
        shouldRemovedDirs.isNotEmpty &&
        shouldRemovedDirs.every((dir) => _isManagedPath(dir.path))) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          var dir = Directory(c.baseDir);
          if (dir.existsSync() && c.managedByApp && _isManagedPath(dir.path)) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    final paths = directories.map((dir) => dir.path).toList();
    final root = path_utils.canonicalize(LocalManager().path);
    unawaited(
      Isolate.run(() async {
            var errors = <String>[];
            await SAFTaskWorker().init();
            await overrideIO(() async {
              for (var path in paths) {
                var dir = Directory(path);
                try {
                  final target = path_utils.canonicalize(path);
                  var current = target;
                  var safe =
                      target != root && path_utils.isWithin(root, target);
                  while (safe) {
                    if (FileSystemEntity.typeSync(
                          current,
                          followLinks: false,
                        ) ==
                        FileSystemEntityType.link) {
                      safe = false;
                      break;
                    }
                    if (current == root) break;
                    final parent = path_utils.dirname(current);
                    if (parent == current ||
                        !path_utils.isWithin(root, parent)) {
                      safe = false;
                      break;
                    }
                    current = parent;
                  }
                  if (!safe) {
                    throw const FileSystemException(
                      'Refusing to delete a path outside local storage',
                    );
                  }
                  for (var attempt = 0; attempt < 3; attempt++) {
                    if (!await dir.exists()) {
                      break;
                    }
                    if (FileSystemEntity.typeSync(
                          dir.path,
                          followLinks: false,
                        ) ==
                        FileSystemEntityType.link) {
                      throw const FileSystemException(
                        'Refusing to delete a symbolic link',
                      );
                    }
                    try {
                      await dir.delete(recursive: true);
                    } catch (e) {
                      if (attempt == 2) rethrow;
                    }
                    if (!await dir.exists()) {
                      break;
                    }
                    await Future.delayed(
                      Duration(milliseconds: 100 * (attempt + 1)),
                    );
                  }
                  if (await dir.exists()) {
                    throw FileSystemException(
                      'Directory still exists after delete retries',
                      dir.path,
                    );
                  }
                } catch (e, s) {
                  errors.add(
                    "Failed to delete local directory ${dir.path}: "
                    "$e\n${s.toString()}",
                  );
                }
              }
            });
            return errors;
          })
          .then((errors) {
            for (var error in errors) {
              Log.error("LocalManager", error);
            }
          })
          .catchError((e, s) {
            Log.error(
              "LocalManager",
              "Failed to run local directory cleanup: $e",
              s,
            );
          }),
    );
  }

  bool _isManagedPath(String candidate) {
    final root = path_utils.canonicalize(path);
    final target = path_utils.canonicalize(candidate);
    if (target == root || !path_utils.isWithin(root, target)) return false;

    // A canonical string alone does not protect against an existing symlink
    // in a path component. Reject links before any caller writes or deletes.
    var current = target;
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      if (current == root) break;
      final parent = path_utils.dirname(current);
      if (parent == current || !path_utils.isWithin(root, parent)) {
        return false;
      }
      current = parent;
    }
    return true;
  }

  bool isManagedPath(String candidate) => _isManagedPath(candidate);

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

class LocalRefreshResult {
  final int discovered;
  final int updated;
  final int missing;
  final bool canceled;

  const LocalRefreshResult(
    this.discovered,
    this.updated,
    this.missing,
    this.canceled,
  );
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
