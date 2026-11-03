import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/reader_appearance.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

import 'support/test_translations.dart';

class _NoDataSync extends Fake implements DataSync {
  @override
  void onDataChanged() {}

  @override
  Future<Res<bool>> uploadData({bool force = false}) async => const Res(true);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<dynamic> openReader(
  WidgetTester tester,
  String mode, {
  Map<int, Size> imageSizes = const {},
}) async {
  tester.view.physicalSize = const Size(1000, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await ensureTestTranslations();
  final root = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('reader-margin-'),
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
  final values = <String, dynamic>{
    'readerMode': mode,
    'readerPageMarginEnabled': true,
    'readerPageMarginPercent': 19.3,
    'readerTwoPageSpread': false,
    'readerSpreadOverrides': <String, dynamic>{},
    'showSingleImageOnFirstPage': false,
    'readerScreenPicNumberForLandscape': 1,
    'readerScreenPicNumberForPortrait': 1,
    'enablePageAnimation': false,
    'limitImageWidth': true,
    'enableClockAndBatteryInfoInReader': false,
    'enableTurnPageByVolumeKey': false,
    'recordReadingStatistics': false,
    'removeReadLaterOnComplete': false,
    'enableLongPressToZoom': true,
    'comicSpecificSettings': <String, dynamic>{},
    'deviceSpecificSettings': <String, dynamic>{},
    'deviceId': 'reader-margin-device',
    'webdav': <String>[],
  };
  final previous = {for (final key in values.keys) key: appdata.settings[key]};
  for (final entry in values.entries) {
    appdata.settings[entry.key] = entry.value;
  }
  final local = LocalManager();
  late LocalComic comic;
  await tester.runAsync(() async {
    final dir = Directory('${root.path}/local/comic')
      ..createSync(recursive: true);
    File('${root.path}/local_path').writeAsStringSync('${root.path}/local');
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 320, 320),
      Paint()..color = Colors.orange,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(320, 320);
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    for (var i = 1; i <= 30; i++) {
      final size = imageSizes[i];
      if (size == null) {
        File('${dir.path}/$i.png').writeAsBytesSync(bytes);
      } else {
        final recorder = ui.PictureRecorder();
        Canvas(
          recorder,
        ).drawRect(Offset.zero & size, Paint()..color = Colors.orange);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        File('${dir.path}/$i.png').writeAsBytesSync(data.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      }
    }
    await local.init();
    await LocalFavoritesManager().init();
    await HistoryManager().init();
    comic = LocalComic(
      id: 'margin-test',
      title: 'Margin test',
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
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    // Drain queued saves in both the fake clock and the real filesystem before
    // removing the fixture directory.
    await settle(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await root.delete(recursive: true);
    });
    for (final entry in previous.entries) {
      appdata.settings[entry.key] = entry.value;
    }
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
        initialPage: 10,
        history: History.fromModel(model: comic, ep: 1, page: 10),
        author: '',
        tags: [],
      ),
    ),
  );
  await settle(tester);
  final dynamic state = tester.state(find.byType(Reader));
  for (var i = 0; i < 20 && state.images == null; i++) {
    await settle(tester);
  }
  expect(state.images, hasLength(30));
  for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
    await settle(tester);
  }
  expect(find.byType(RawImage), findsWidgets);
  return state;
}

Future<void> pinch(WidgetTester tester, Offset center) async {
  final first = await tester.startGesture(
    center - const Offset(50, 0),
    pointer: 1,
  );
  final second = await tester.startGesture(
    center + const Offset(50, 0),
    pointer: 2,
  );
  await tester.pump();
  for (var i = 1; i <= 5; i++) {
    await first.moveTo(center - Offset(50 + i * 12, 0));
    await second.moveTo(center + Offset(50 + i * 12, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await first.up();
  await second.up();
  await settle(tester);
}

void main() {
  late DataSync? previousSync;
  setUp(() {
    previousSync = DataSync.instance;
    DataSync.instance = _NoDataSync();
  });
  tearDown(() => DataSync.instance = previousSync);

  testWidgets(
    'toolbar previews page margins during a drag on a narrow reader',
    (tester) async {
      final dynamic state = await openReader(tester, 'continuousTopToBottom');
      tester.view.physicalSize = const Size(360, 800);
      await settle(tester);
      await tester.tapAt(tester.getRect(find.byType(Reader)).center);
      await settle(tester);
      await tester.tap(find.byKey(const Key('reader-page-margin-toggle')));
      await settle(tester);
      final controls = find.byKey(const Key('reader-page-margin-controls'));
      final slider = find.descendant(
        of: controls,
        matching: find.byType(Slider),
      );
      final image = find.byKey(const ValueKey('reader-continuous-image-10'));
      final before = tester.getSize(image).width;
      final rect = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * .45, rect.center.dy),
      );
      await gesture.moveTo(
        Offset(rect.left + rect.width * .75, rect.center.dy),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Slider>(slider).divisions, isNull);
      expect(tester.getSize(image).width, lessThan(before));
      expect(state.page, 10);
      expect(
        tester.widget<Slider>(slider).value,
        appdata.settings['readerPageMarginPercent'],
      );
      await gesture.up();
      await settle(tester);
      await tester.tap(
        find.descendant(of: controls, matching: find.byType(Switch)),
      );
      await settle(tester);
      expect(readerPageMargin(state.cid, state.type.sourceKey), 0);
      appdata.settings.setEnabledDeviceSpecificSettings(true);
      state.update();
      await settle(tester);
      await tester.drag(slider, const Offset(-35, 0));
      await settle(tester);
      expect(appdata.settings['readerPageMarginEnabled'], false);
      expect(
        appdata.settings.getDeviceReaderSetting('readerPageMarginEnabled'),
        true,
      );
      final deviceMargin = appdata.settings.getDeviceReaderSetting(
        'readerPageMarginPercent',
      );
      appdata.settings.setEnabledComicSpecificSettings(
        state.cid,
        state.type.sourceKey,
        true,
      );
      state.update();
      await settle(tester);
      final scopedControl = tester.widget<ReaderPageMarginSetting>(
        find.descendant(
          of: controls,
          matching: find.byType(ReaderPageMarginSetting),
        ),
      );
      expect(scopedControl.comicId, state.cid);
      // Slider drags begin at an absolute track position. Repeating the same
      // drag selects the same percentage even when a different scope is active.
      await tester.drag(slider, const Offset(-55, 0));
      await settle(tester);
      expect(
        appdata.settings.getDeviceReaderSetting('readerPageMarginPercent'),
        deviceMargin,
      );
      expect(
        appdata.settings.getReaderSetting(
          state.cid,
          state.type.sourceKey,
          'readerPageMarginPercent',
        ),
        isNot(deviceMargin),
      );
      await tester.tap(find.byKey(const Key('reader-page-margin-toggle')));
      await settle(tester);
      expect(controls, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );

  testWidgets(
    'single image actions shift spreads and multi-image screens in reading order',
    (tester) async {
      final dynamic state = await openReader(tester, 'galleryLeftToRight');
      appdata.settings['readerTwoPageSpread'] = true;
      state.update();
      await settle(tester);
      await tester.tapAt(tester.getRect(find.byType(Reader)).center);
      await settle(tester);
      expect(state.imageLayout.range(state.page), (8, 10));
      await tester.tap(find.byKey(const Key('reader-next-image')));
      await settle(tester);
      expect(state.imageLayout.range(state.page), (9, 11));
      expect(state.history.page, 10);
      await tester.tap(find.byKey(const Key('reader-previous-image')));
      await settle(tester);
      expect(state.imageLayout.range(state.page), (8, 10));
      await tester.tap(find.byKey(const Key('reader-previous-image')));
      await settle(tester);
      expect(state.imageLayout.range(state.page), (7, 9));
      state.toNextPage();
      await settle(tester);
      expect(state.imageLayout.range(state.page), (9, 11));
      state.mode = ReaderMode.galleryRightToLeft;
      state.update();
      await settle(tester);
      expect(state.imageLayout.range(state.page), (9, 11));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('reader-spread-image-11')))
            .right,
        closeTo(
          tester
              .getRect(find.byKey(const ValueKey('reader-spread-image-10')))
              .left,
          .1,
        ),
      );
      tester.view.physicalSize = const Size(600, 1000);
      await settle(tester);
      expect(state.imageLayout.range(state.page), (9, 11));
      state.toPage(1, animate: false);
      await settle(tester);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reader-previous-image')))
            .onPressed,
        isNull,
      );
      state.toPage(state.maxPage, animate: false);
      await settle(tester);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reader-next-image')))
            .onPressed,
        isNull,
      );
      appdata.settings['readerTwoPageSpread'] = false;
      appdata.settings['readerScreenPicNumberForLandscape'] = 4;
      appdata.settings['readerScreenPicNumberForPortrait'] = 4;
      state.update();
      await settle(tester);
      state.toPage(3, animate: false);
      await settle(tester);
      expect(state.imageLayout.range(state.page), (8, 12));
      state.shiftImage(1);
      await settle(tester);
      expect(state.imageLayout.range(state.page), (9, 13));
      state.toNextPage();
      await settle(tester);
      expect(state.imageLayout.range(state.page), (13, 17));
      state.mode = ReaderMode.galleryTopToBottom;
      state.update();
      await settle(tester);
      state.shiftImage(-1);
      await settle(tester);
      expect(state.imageLayout.range(state.page), (12, 16));
      appdata.settings['showSingleImageOnFirstPage'] = true;
      state.update();
      await settle(tester);
      state.toPage(2, animate: false);
      await settle(tester);
      state.shiftImage(-1);
      await settle(tester);
      expect(state.page, 1);
      expect(state.imageLayout.range(state.page), (0, 2));
      state.resetImageGrouping();
      state.page = 1;
      state.update();
      await settle(tester);
      state.shiftImage(1);
      await settle(tester);
      expect(state.page, 1);
      expect(state.imageLayout.range(state.page), (0, 2));
      expect(
        tester
            .widget<PhotoViewGallery>(find.byType(PhotoViewGallery))
            .pageController!
            .page,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );

  testWidgets(
    'margin controls accept precise values and reject invalid percentages',
    (tester) async {
      await openReader(tester, 'continuousTopToBottom');
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Scaffold(body: ReaderSettings(onChanged: changes.add)),
        ),
      );
      await settle(tester);
      await tester.scrollUntilVisible(
        find.text('19.3%'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('19.3%'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '45');
      await tester.tap(find.text('Confirm'.tl));
      await tester.pumpAndSettle();
      expect(find.text('Enter a percentage from 0 to 40.'.tl), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '21.7');
      await tester.tap(find.text('Confirm'.tl));
      await settle(tester);
      expect(appdata.settings['readerPageMarginPercent'], 21.7);
      expect(changes, contains('readerPageMarginPercent'));
      expect(find.text('21.7%'), findsOneWidget);
      final title = find.text('Page margin'.tl);
      final tile = find.ancestor(of: title, matching: find.byType(ListTile));
      await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
      await settle(tester);
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      // The dependent UI must be notified before asynchronous disk writes finish.
      expect(changes, contains('readerPageMarginEnabled'));
      await settle(tester);
      expect(appdata.settings['readerPageMarginEnabled'], false);
      expect(changes, contains('readerPageMarginEnabled'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );

  testWidgets(
    'vertical margins retain reading location, resize and pinch gestures',
    (tester) async {
      final dynamic state = await openReader(tester, 'continuousTopToBottom');
      final image = find.byKey(const ValueKey('reader-continuous-image-10'));
      final viewport = tester.getRect(find.byType(Reader));
      expect(tester.getSize(image).width, closeTo(viewport.width * .614, 0.1));
      expect(
        tester.getTopLeft(image).dx,
        closeTo(viewport.left + viewport.width * .193, 0.1),
      );
      final list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      list.itemScrollController!.jumpTo(index: 10, alignment: -0.2);
      await settle(tester);
      final before = tester.getRect(image);
      final fraction = (viewport.top - before.top) / before.height;
      appdata.settings['readerPageMarginPercent'] = 30.0;
      state.update();
      await settle(tester);
      expect(state.page, 10);
      expect(tester.getSize(image).width, closeTo(viewport.width * .4, 0.1));
      final after = tester.getRect(image);
      expect(
        (viewport.top - after.top) / after.height,
        closeTo(fraction, 0.01),
      );
      tester.view.physicalSize = const Size(600, 1000);
      await settle(tester);
      expect(state.page, 10);
      expect(
        tester.getSize(image).width,
        closeTo(tester.getSize(find.byType(Reader)).width * .4, 0.1),
      );
      final photo = tester.widget<PhotoView>(find.byType(PhotoView));
      await pinch(tester, const Offset(300, 450));
      expect(photo.controller!.scale, greaterThan(1.1));
      photo.controller!.scale = 1;
      photo.controller!.position = Offset.zero;
      await settle(tester);
      await tester.dragFrom(const Offset(15, 700), const Offset(0, -600));
      await settle(tester);
      expect(state.page, greaterThan(10));
      final page = state.page;
      appdata.settings['readerPageMarginEnabled'] = false;
      state.update();
      await settle(tester);
      expect(state.page, page);
      expect(readerPageMargin(state.cid, state.type.sourceKey), 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );

  testWidgets(
    'horizontal continuous margins leave top and bottom, retaining RTL order',
    (tester) async {
      final dynamic state = await openReader(tester, 'continuousRightToLeft');
      final image = find.byKey(const ValueKey('reader-continuous-image-10'));
      final viewport = tester.getRect(find.byType(Reader));
      expect(
        tester.getSize(image).height,
        closeTo(viewport.height * .614, 0.1),
      );
      expect(
        tester.getTopLeft(image).dy,
        closeTo(viewport.top + viewport.height * .193, 0.1),
      );
      final page = state.page;
      await tester.dragFrom(
        Offset(300, viewport.top + viewport.height * 0.1),
        const Offset(550, 0),
      );
      await settle(tester);
      expect(state.page, greaterThan(page));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );

  testWidgets(
    'gallery margins retain single-page zoom, spread order and page on rotation',
    (tester) async {
      final dynamic state = await openReader(tester, 'galleryLeftToRight');
      final viewport = tester.getRect(find.byType(Reader));
      final raw = find.byType(RawImage).first;
      expect(
        tester.getSize(raw).width,
        closeTo(viewport.size.shortestSide * .614, 1),
      );
      appdata.settings['readerPageMarginPercent'] = 30.0;
      state.update();
      await settle(tester);
      expect(
        tester.getSize(raw).width,
        closeTo(viewport.size.shortestSide * .4, 1),
      );
      appdata.settings['readerPageMarginPercent'] = 19.3;
      state.update();
      await settle(tester);
      await pinch(tester, const Offset(500, 300));
      expect(tester.getSize(raw).width, greaterThan(400));
      final zoomedWidth = tester.getSize(raw).width;
      appdata.settings['readerPageMarginPercent'] = 30.0;
      state.update();
      await settle(tester);
      expect(tester.getSize(raw).width, closeTo(zoomedWidth * .4 / .614, 1));
      expect(state.page, 10);
      final longPress = await tester.startGesture(const Offset(500, 300));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      await longPress.up();
      await settle(tester);
      expect(
        tester.getSize(raw).width,
        closeTo(viewport.size.shortestSide * .4, 1),
      );
      appdata.settings['readerPageMarginPercent'] = 19.3;
      appdata.settings['readerTwoPageSpread'] = true;
      state.update();
      await settle(tester);
      expect(state.page, 5);
      Finder image(int n) => find.byKey(ValueKey('reader-spread-image-$n'));
      expect(
        tester.getRect(image(9)).left,
        closeTo(viewport.left + viewport.width * .193, 0.1),
      );
      expect(
        tester.getRect(image(10)).right,
        closeTo(viewport.right - viewport.width * .193, 0.1),
      );
      expect(
        tester.getRect(image(9)).right,
        closeTo(tester.getRect(image(10)).left, 0.1),
      );
      state.mode = ReaderMode.galleryRightToLeft;
      state.update();
      await settle(tester);
      expect(state.page, 5);
      expect(
        tester.getRect(image(10)).right,
        closeTo(tester.getRect(image(9)).left, 0.1),
      );
      tester.view.physicalSize = const Size(600, 1000);
      await settle(tester);
      expect(state.page, 5);
      final rotated = tester.getRect(find.byType(Reader));
      expect(
        tester.getRect(image(10)).left,
        closeTo(rotated.left + rotated.width * .193, 0.1),
      );
      expect(
        tester.getRect(image(9)).right,
        closeTo(rotated.right - rotated.width * .193, 0.1),
      );
      final unzoomed = tester.getRect(image(9)).width;
      await pinch(tester, const Offset(300, 500));
      expect(tester.getRect(image(9)).width, greaterThan(unzoomed * 1.1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
    },
  );
}
