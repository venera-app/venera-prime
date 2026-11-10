// Manual diagnostic APK. Never run on the production package.
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/network/download_page.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('PRIME_SAF_PROVIDER_PROBE')) {
    throw StateError('Opt-in required');
  }
  final status = ValueNotifier('Starting');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, text, _) => Text(text),
          ),
        ),
      ),
    ),
  );
  final support = await getApplicationSupportDirectory();
  App.dataPath = support.path;
  App.cachePath = (await getTemporaryDirectory()).path;
  final log = File('${support.path}/provider-probe.log');
  void record(String message) {
    log.writeAsStringSync('$message\n', mode: FileMode.append, flush: true);
    status.value = message;
  }

  void check(bool value, String description) {
    if (!value) throw StateError(description);
    record('PASS $description');
  }

  await SAFTaskWorker().init();
  try {
    await overrideIO(() async {
      final saved = File('${support.path}/probe-tree');
      final String path;
      if (saved.existsSync()) {
        path = saved.readAsStringSync();
        record('RESTART reopen persisted tree');
        check(
          await File('$path/comic/chapter/1.png').exists(),
          'previous launch page survives restart',
        );
      } else {
        record('Select Prime opaque test storage');
        path = (await AndroidDirectory.pickDirectory())!.path;
        saved.writeAsStringSync(path);
      }
      final root = Directory(path);
      check(await root.exists(), 'tree exists');
      final dir = Directory('$path/comic/chapter')..createSync(recursive: true);
      const text = '章节一\n测试 metadata ü';
      final metadata = File('${dir.path}/metadata|测试.txt');
      await metadata.writeAsString(text);
      check(
        await File(metadata.path).readAsString() == text,
        'UTF8 text with opaque ID reopen',
      );
      check(metadata.readAsLinesSync().length == 2, 'text lines');
      check(
        (await dir.stat()).type == FileSystemEntityType.directory,
        'directory metadata',
      );
      check(
        (await metadata.stat()).size == utf8.encode(text).length,
        'file metadata size',
      );
      check(
        FileSystemEntity.typeSync(metadata.path) == FileSystemEntityType.file,
        'IO override type',
      );
      check(
        (await dir.list().toList()).any((e) => e.path == metadata.path),
        'listing pipe character and Unicode',
      );
      final rejected = File('${dir.path}/reject-write.bin')..createSync();
      var failed = false;
      try {
        await rejected.writeAsBytes([1, 2, 3]);
      } on FileSystemException {
        failed = true;
      }
      check(failed, 'write failures propagated');
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      );
      await File('$path/comic/cover.png').writeAsBytes(image);
      await File('${dir.path}/.1.error.txt').writeAsString('previous failure');
      await writeDownloadedPage(File('${dir.path}/1.png'), 1, image);
      check(
        !await File('${dir.path}/.1.error.txt').exists(),
        'download writes page and clears sibling error marker',
      );
      await File(
        '$path/comic/metadata.json',
      ).writeAsString(jsonEncode({'title': 'Opaque provider comic'}));
      File('${support.path}/local_path').writeAsStringSync(path);
      final local = LocalManager();
      await local.init();
      final refresh = await local.refresh();
      record('refresh $refresh');
      final comics = local.search('');
      check(comics.isNotEmpty, 'refresh discovered comic');
      final comic = comics.first;
      check(comic.createdAt.year > 2020, 'unknown timestamp fallback');
      check(local.isManagedPath('$path/comic/chapter'), 'managed SAF child');
      check(
        !local.isManagedPath('$path/comic/../outside'),
        'reject SAF traversal',
      );
      final epub = await createEpubWithLocalComic(
        comic,
        '${App.cachePath}/provider.epub',
      );
      final archive = ZipDecoder().decodeBytes(epub.readAsBytesSync());
      check(
        archive.files.any((f) => f.name.endsWith('.png')),
        'EPUB from nonseekable provider',
      );
      local.close();
      final originalPath = metadata.path;
      final copy = await metadata.copy('${dir.path}/copy.txt');
      check(
        await metadata.readAsString() == text &&
            await copy.readAsString() == text,
        'copy preserves original handle',
      );
      check(
        metadata.path == originalPath,
        'copy leaves original path unchanged',
      );
      await copy.delete();
      check(!await copy.exists(), 'deleted handle exists false');
      await rejected.delete();
      await local.init();
      final native = Directory('${support.path}/native-migration')
        ..createSync();
      check(
        await local.setNewPath(native.path) == null,
        'migrate provider to native storage',
      );
      check(
        File('${native.path}/comic/chapter/1.png').readAsBytesSync().length ==
            image.length,
        'migration copies nonseekable page',
      );
      check(
        await local.setNewPath(path) == null,
        'migrate native storage to provider',
      );
      local.close();
      await local.init();
      check(
        local.path == path && await File('$path/comic/chapter/1.png').exists(),
        'reopen migrated library',
      );
      final deleteDir = Directory('$path/delete-me')..createSync();
      File('${deleteDir.path}/page.png').writeAsBytesSync(image);
      final removable = LocalComic(
        id: 'provider-delete',
        title: 'delete',
        subtitle: '',
        tags: [],
        directory: 'delete-me',
        chapters: null,
        cover: 'page.png',
        comicType: ComicType.local,
        downloadedChapters: [],
        createdAt: DateTime.now(),
      );
      await local.add(removable);
      local.batchDeleteComics([removable], true, false);
      for (
        var i = 0;
        i < 100 && await Directory(deleteDir.path).exists();
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      check(
        !await Directory(deleteDir.path).exists(),
        'managed background deletion removes provider directory',
      );
      local.close();
      final offline = File('${support.path}/provider-offline');
      offline.writeAsStringSync('offline');
      try {
        var listFailed = false;
        try {
          await root.list().toList();
        } on FileSystemException {
          listFailed = true;
        }
        check(listFailed, 'offline listing throws instead of returning empty');
        await local.init();
        check(
          local.path == path &&
              File('${support.path}/local_path').readAsStringSync() == path,
          'offline startup preserves configured tree',
        );
      } finally {
        offline.deleteSync();
        local.close();
      }
      record('PASS ALL; restart app to repeat persisted-tree checks');
    });
  } catch (e, s) {
    record('FAIL $e\n$s');
  }
}
