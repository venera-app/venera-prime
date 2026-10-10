import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

void registerReaderSpreadTests({bool device = false}) {
  testWidgets(
    'two-page spreads preserve pairs, direction, last-page blank and position',
    (tester) async {
      if (!device) tester.view.physicalSize = const Size(1000, 600);
      if (!device) tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppTranslation.init();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader-scrub-'),
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
      appdata.settings['readerMode'] = 'galleryLeftToRight';
      appdata.settings['readerTwoPageSpread'] = true;
      appdata.settings['showSingleImageOnFirstPage'] = false;
      appdata.settings['enablePageAnimation'] = true;
      appdata.settings['limitImageWidth'] = true;
      appdata.settings['enableClockAndBatteryInfoInReader'] = false;
      appdata.settings['enableTurnPageByVolumeKey'] = false;
      appdata.settings['recordReadingStatistics'] = false;
      appdata.settings['removeReadLaterOnComplete'] = false;
      appdata.settings['webdav'] = [];
      final local = LocalManager();
      late LocalComic comic;
      await tester.runAsync(() async {
        final dir = Directory('${root.path}/local/comic')
          ..createSync(recursive: true);
        File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
        for (var i = 1; i <= 5; i++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 320, 480),
            Paint()
              ..color = i.isOdd
                  ? const Color(0xffffe0b2)
                  : const Color(0xffb3e5fc),
          );
          final text = TextPainter(
            text: TextSpan(
              text: '$i',
              style: const TextStyle(color: Colors.black, fontSize: 140),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          text.paint(
            canvas,
            Offset((320 - text.width) / 2, (480 - text.height) / 2),
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(320, 480);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${dir.path}/$i.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
        await local.init();
        await LocalFavoritesManager().init();
        await HistoryManager().init();
        comic = LocalComic(
          id: 'scrub-test',
          title: 'Scrub test',
          subtitle: '',
          tags: [],
          directory: 'comic',
          chapters: null,
          cover: '1.png',
          comicType: ComicType.local,
          downloadedChapters: [],
          createdAt: DateTime.now(),
        );
        await local.add(comic);
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Reader(
            type: ComicType.local,
            cid: comic.id,
            name: comic.title,
            chapters: null,
            history: History.fromModel(model: comic, ep: 1, page: 1),
            author: '',
            tags: [],
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var i = 0;
        i < 20 &&
            tester.widget<CustomSlider>(find.byType(CustomSlider)).max < 3;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(CustomSlider), findsOneWidget);
      expect(tester.widget<CustomSlider>(find.byType(CustomSlider)).max, 3);
      final dynamic state = tester.state(find.byType(Reader));
      Finder image(int n) => find.byKey(ValueKey('reader-spread-image-$n'));
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
        }
      }

      Future<void> jump(int page) async {
        tester
            .widget<CustomSlider>(find.byType(CustomSlider))
            .onChanged(page.toDouble());
        await settle();
      }

      expect(state.imagesPerPage, 2);
      expect(
        tester.getRect(image(1)).right,
        closeTo(tester.getRect(image(2)).left, 1),
      );
      await jump(2);
      expect(
        tester.getRect(image(3)).right,
        closeTo(tester.getRect(image(4)).left, 1),
      );
      await jump(3);
      expect(image(5), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-spread-blank')), findsOneWidget);
      expect(
        tester.getSize(image(5)).width,
        closeTo(tester.getSize(find.byType(Reader)).width / 2, 1),
      );

      // Switching to single-page and back keeps the same underlying image.
      appdata.settings['readerTwoPageSpread'] = false;
      state.update();
      await settle();
      expect(state.page, 5);
      appdata.settings['readerTwoPageSpread'] = true;
      state.update();
      await settle();
      expect(state.page, 3);
      state.mode = ReaderMode.galleryRightToLeft;
      state.update();
      await settle();
      await jump(1);
      expect(
        tester.getRect(image(2)).right,
        closeTo(tester.getRect(image(1)).left, 1),
      );
      final viewport = tester.getRect(find.byType(Reader));
      await tester.dragFrom(viewport.center, Offset(viewport.width * 0.7, 0));
      await settle();
      expect(state.page, 2);
      expect(image(3), findsOneWidget);
      expect(image(4), findsOneWidget);
      await tester.dragFrom(viewport.center, Offset(-viewport.width * 0.7, 0));
      await settle();
      expect(state.page, 1);
      if (device) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
        ]);
        await settle();
        expect(state.imagesPerPage, 2);
        expect(state.page, 1);
        print('DEVICE_SPREAD_RTL_READY');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 8)),
        );
      } else {
        tester.view.physicalSize = const Size(600, 1000);
        await settle();
        expect(state.imagesPerPage, 2);
        expect(state.page, 1);
      }
      appdata.settings['showSingleImageOnFirstPage'] = true;
      state.update();
      await settle();
      expect(image(1), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-spread-blank')), findsOneWidget);
      await jump(2);
      expect(
        tester.getRect(image(3)).right,
        closeTo(tester.getRect(image(2)).left, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: const SizedBox(),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
