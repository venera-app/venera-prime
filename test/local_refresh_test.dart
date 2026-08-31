import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

void main() {
  test(
    'refresh keeps source chapters while detecting downloaded directories',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-local-refresh-',
      );
      final localDirectory = Directory('${directory.path}/local')
        ..createSync(recursive: true);
      App.dataPath = directory.path;
      File(
        '${directory.path}/local_path',
      ).writeAsStringSync(localDirectory.path);

      final comicDirectory = Directory('${localDirectory.path}/cached-comic')
        ..createSync();
      final chapterDirectory = Directory('${comicDirectory.path}/1')
        ..createSync();
      File('${chapterDirectory.path}/1.jpg').writeAsBytesSync([1]);

      final manager = LocalManager();
      manager.close();
      await manager.init();
      await manager.add(
        LocalComic(
          id: 'network-id',
          title: 'Cached comic',
          subtitle: 'Author',
          tags: [],
          directory: 'cached-comic',
          chapters: ComicChapters({'1': 'Chapter 1', '2': 'Chapter 2'}),
          cover: '1/1.jpg',
          comicType: ComicType(123),
          downloadedChapters: ['1'],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      await manager.refresh();
      final refreshed = manager.find('network-id', const ComicType(123));
      expect(refreshed, isNotNull);
      expect(refreshed!.chapters!.allChapters, {
        '1': 'Chapter 1',
        '2': 'Chapter 2',
      });
      expect(refreshed.downloadedChapters, ['1']);

      manager.close();
      await directory.delete(recursive: true);
    },
  );
}
