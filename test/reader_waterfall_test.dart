import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

Future<void> _waitForContinuousImages(WidgetTester tester) async {
  if (find.byType(Reader).evaluate().isEmpty ||
      !appdata.settings['readerMode'].toString().startsWith('continuous')) {
    return;
  }
  bool imagesDecoded() {
    final images = find.byType(ComicImage);
    return images.evaluate().isNotEmpty &&
        images.evaluate().every(
          (element) => find
              .descendant(
                of: find.byWidget(element.widget),
                matching: find.byType(RawImage),
              )
              .evaluate()
              .isNotEmpty,
        );
  }

  for (var i = 0; i < 60 && !imagesDecoded(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    imagesDecoded(),
    isTrue,
    reason: 'chapter navigation waits for decoded image extents',
  );
}

void main() {
  testWidgets(
    'waterfall prepends without jumping and scrolls both directions across chapters',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppTranslation.init();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('chapter-direction-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = root.path;
      for (final channel in [
        'flutter_memory_info',
        'window_manager',
        'venera/method_channel',
      ]) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
      }
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      appdata.settings['enablePageAnimation'] = false;
      appdata.settings['readerTwoPageSpread'] = false;
      appdata.settings['limitImageWidth'] = false;
      appdata.settings['enableTapToTurnPages'] = true;
      appdata.settings['enableDoubleTapToZoom'] = false;
      appdata.settings['enableClockAndBatteryInfoInReader'] = false;
      appdata.settings['enableTurnPageByVolumeKey'] = false;
      appdata.settings['recordReadingStatistics'] = false;
      appdata.settings['removeReadLaterOnComplete'] = false;
      appdata.settings['webdav'] = [];
      final local = LocalManager();
      late LocalComic comic;
      const chapters = ComicChapters({'ep1': 'First', 'ep2': 'Second'});
      await tester.runAsync(() async {
        File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        );
        for (final ep in chapters.ids) {
          final dir = Directory('${root.path}/local/comic/$ep')
            ..createSync(recursive: true);
          for (var i = 1; i <= 2; i++) {
            File('${dir.path}/$i.png').writeAsBytesSync(bytes);
          }
        }
        await local.init();
        await LocalFavoritesManager().init();
        await HistoryManager().init();
        comic = LocalComic(
          id: 'direction',
          title: 'Direction',
          subtitle: '',
          tags: [],
          directory: 'comic',
          chapters: chapters,
          cover: 'ep1/1.png',
          comicType: ComicType.local,
          downloadedChapters: chapters.ids.toList(),
          createdAt: DateTime.now(),
        );
        await local.add(comic);
      });
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        await _waitForContinuousImages(tester);
      }

      appdata.settings['readerMode'] = 'continuousTopToBottom';
      appdata.settings['readerWaterfall'] = true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => Material(child: WindowFrame(child!)),
          home: Reader(
            type: ComicType.local,
            cid: comic.id,
            name: comic.title,
            chapters: chapters,
            initialChapter: 2,
            history: History.fromModel(model: comic, ep: 2, page: 1),
            author: '',
            tags: [],
          ),
        ),
      );
      await settle();
      await settle();
      final dynamic reader = tester.state(find.byType(Reader));
      expect(reader.chapter, 2);
      final list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      expect(
        list.itemCount,
        8,
      ); // Two chapters, each heading + two images, and two edges.
      list.itemScrollController!.jumpTo(index: 2);
      await settle();
      expect(reader.chapter, 1);
      expect(reader.page, 1);
      list.itemScrollController!.jumpTo(index: 5);
      await settle();
      expect(reader.chapter, 2);
      expect(reader.page, 1);
      // Explicit navigation resets the stream and still resolves the correct page.
      reader.toChapter(1);
      await settle();
      expect(reader.chapter, 1);
      reader.toPage(2, animate: false);
      await settle();
      expect(reader.page, 2);
      expect(reader.history.ep, 1);
      appdata.settings['comicChapterReadingOrder'] = <String, dynamic>{
        '${comic.id}@${ComicType.local.sourceKey}': 'reverse',
      };
      reader.toChapter(2);
      await settle();
      await settle();
      final reverseList = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      expect(reverseList.itemCount, 8);
      reverseList.itemScrollController!.jumpTo(index: 5);
      await settle();
      expect(reader.chapter, 1);
      expect(reader.history.ep, 1);
      appdata.settings['comicChapterReadingOrder'] = <String, dynamic>{};
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => Material(child: WindowFrame(child!)),
          home: const SizedBox(),
        ),
      );
      await settle();
      appdata.settings['readerWaterfall'] = false;
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
