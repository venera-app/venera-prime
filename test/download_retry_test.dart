import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/download_page.dart';

class _Source implements ComicSource {
  @override
  String get key => 'retry-test';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      task.dispose();
      manager.close();
      await directory.delete(recursive: true);
    },
  );
}
