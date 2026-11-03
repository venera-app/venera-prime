import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/download_page.dart';
import 'package:venera/utils/translations.dart';

class _Source implements ComicSource {
  @override
  String get key => 'retry-test';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Model SAF listing handles whose metadata query reports an empty file,
// although reopening the same path gives a valid document.
class _ListedFile implements File {
  @override
  final String path;
  _ListedFile(this.path);
  @override
  int lengthSync() => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ListedDirectory implements Directory {
  final Directory actual;
  _ListedDirectory(this.actual);
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => actual
      .listSync(recursive: recursive, followLinks: followLinks)
      .map((entity) => entity is File ? _ListedFile(entity.path) : entity)
      .toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ListingOverrides extends IOOverrides {
  final String directory;
  _ListingOverrides(this.directory);
  @override
  Directory createDirectory(String path) {
    final actual = super.createDirectory(path);
    return path == directory ? _ListedDirectory(actual) : actual;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  for (final withChapters in [false, true]) {
    test(
      'SAF listed images complete after a path change (chapters=$withChapters)',
      () async {
        final directory = await Directory.systemTemp.createTemp('prime-saf-');
        final oldStorage = Directory('${directory.path}/old')..createSync();
        final newStorage = Directory('${directory.path}/new')..createSync();
        App.dataPath = directory.path;
        File('${directory.path}/local_path').writeAsStringSync(oldStorage.path);
        final manager = LocalManager();
        manager.close();
        await manager.init();
        final source = _Source();
        ComicSourceManager().add(source);
        ImagesDownloadTask? task;
        try {
          expect(await manager.setNewPath(newStorage.path), isNull);
          final comic = Directory('${newStorage.path}/comic')..createSync();
          final pages = withChapters
              ? (Directory('${comic.path}/1')..createSync())
              : comic;
          File('${pages.path}/0.jpg').writeAsBytesSync([1, 2, 3]);
          task = ImagesDownloadTask.fromJson({
            'type': 'ImagesDownloadTask',
            'source': source.key,
            'comicId': 'comic',
            'comic': {
              'title': 'SAF comic',
              'cover': '',
              'tags': <String, dynamic>{},
              if (withChapters) 'chapters': {'1': 'One'},
              'sourceKey': source.key,
              'comicId': 'comic',
            },
            'path': comic.path,
            'cover': 'file://${comic.path}/cover.jpg',
            'images': {
              withChapters ? '1' : '': ['existing'],
            },
            'downloadedCount': 0,
            'totalCount': 1,
            'index': 0,
            'chapter': 0,
          })!;
          final completed = Completer<void>();
          void onComplete() {
            if (manager.find('comic', task!.comicType) != null &&
                !completed.isCompleted) {
              completed.complete();
            }
          }

          manager.addListener(onComplete);
          try {
            await IOOverrides.runWithIOOverrides(() async {
              task!.resume();
              await completed.future.timeout(const Duration(seconds: 5));
              await task.settled;
            }, _ListingOverrides(pages.path));
            expect(task.isError, isFalse);
            expect(task.progress, 1);
            await Future<void>.delayed(Duration.zero);
            expect(
              BackgroundTasks.instance.latest(task.backgroundTaskKey)!.status,
              BackgroundTaskStatus.completed,
            );
            expect(
              manager.find('comic', task.comicType)!.downloadedChapters,
              withChapters ? ['1'] : isEmpty,
            );
          } finally {
            manager.removeListener(onComplete);
          }
          manager.downloadingTasks.add(task);
          expect(await manager.setNewPath(oldStorage.path), isNotNull);
          expect(manager.path, newStorage.path);
          manager.downloadingTasks.clear();
        } finally {
          task?.pause();
          await task?.settled;
          task?.dispose();
          await manager.saveCurrentDownloadingTasks();
          manager.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'successful retry removes the marker and obsolete PNG placeholder',
    () async {
      final directory = await Directory.systemTemp.createTemp('prime-retry-');
      try {
        final marker = File('${directory.path}/.0.error.txt')
          ..writeAsStringSync('failed');
        final placeholder = File('${directory.path}/0.png')
          ..writeAsBytesSync([1]);
        final successfulPage = File('${directory.path}/1.jpg')
          ..writeAsBytesSync([9]);
        final target = File('${directory.path}/0.jpg');
        await writeDownloadedPage(target, 0, [2, 3]);
        expect(target.readAsBytesSync(), [2, 3]);
        expect(marker.existsSync(), isFalse);
        expect(placeholder.existsSync(), isFalse);
        expect(successfulPage.readAsBytesSync(), [9]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'failed replacement retains the error marker for another retry',
    () async {
      final directory = await Directory.systemTemp.createTemp('prime-retry-');
      try {
        final marker = File('${directory.path}/.0.error.txt')
          ..writeAsStringSync('failed');
        Directory('${directory.path}/0.jpg').createSync();
        await expectLater(
          writeDownloadedPage(File('${directory.path}/0.jpg'), 0, [2]),
          throwsA(isA<FileSystemException>()),
        );
        expect(marker.existsSync(), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'restored end-of-chapter cursor rewinds without counting existing pages twice',
    () async {
      final directory = await Directory.systemTemp.createTemp('prime-retry-');
      final local = Directory('${directory.path}/local')..createSync();
      App.dataPath = directory.path;
      File('${directory.path}/local_path').writeAsStringSync(local.path);
      final manager = LocalManager();
      manager.close();
      await manager.init();
      expect(manager.isManagedPath(local.path), isFalse);
      expect(manager.isManagedPath(directory.path), isFalse);
      expect(manager.isManagedPath('${local.path}-outside/comic'), isFalse);
      expect(manager.isManagedPath('${local.path}/comic'), isTrue);
      final link = Link('${local.path}/escape')..createSync(directory.path);
      expect(manager.isManagedPath('${link.path}/comic'), isFalse);
      ComicSourceManager().add(_Source());
      final comic = Directory('${local.path}/comic')..createSync();
      final chapter = Directory('${comic.path}/1')..createSync();
      File('${chapter.path}/0.jpg').writeAsBytesSync([1]);
      final task = ImagesDownloadTask.fromJson({
        'type': 'ImagesDownloadTask',
        'source': 'retry-test',
        'comicId': 'comic',
        'comic': {
          'title': 'Retry',
          'cover': '',
          'tags': <String, dynamic>{},
          'chapters': {'1': 'One'},
          'sourceKey': 'retry-test',
          'comicId': 'comic',
        },
        'path': comic.path,
        'cover': 'file://${comic.path}/cover.jpg',
        'images': {
          '1': ['existing', 'missing'],
        },
        'downloadedCount': 2,
        'totalCount': 2,
        'index': 0,
        'chapter': 1,
      })!;
      final scanned = Completer<void>();
      task.addListener(() {
        if (task.message == '1/2' && !scanned.isCompleted) {
          expect(task.toJson()['chapter'], 0);
          expect(task.toJson()['index'], 0);
          expect(task.progress, 0.5);
          scanned.complete();
          task.pause();
        }
      });
      task.resume();
      await scanned.future.timeout(const Duration(seconds: 5));
      await writeDownloadedPage(File('${chapter.path}/1.jpg'), 1, [2]);
      final completed = Completer<void>();
      void onComplete() {
        if (manager.find('comic', task.comicType) != null &&
            !completed.isCompleted) {
          completed.complete();
        }
      }

      manager.addListener(onComplete);
      task.resume();
      await completed.future.timeout(const Duration(seconds: 5));
      expect(task.progress, 1);
      expect(manager.find('comic', task.comicType)!.downloadedChapters, ['1']);
      manager.removeListener(onComplete);
      await manager.saveCurrentDownloadingTasks();
      await task.settled;
      task.dispose();
      manager.close();
      await directory.delete(recursive: true);
    },
  );
}
