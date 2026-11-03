import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
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

import 'support/test_translations.dart';

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
    'tap direction stays consistent across chapter boundaries in all six modes',
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

      for (final mode in ReaderMode.values) {
        for (final reversed in [false, true]) {
          appdata.settings['readerMode'] = mode.key;
          appdata.settings['reverseTapToTurnPages'] = reversed;
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              // Match main.dart: Reader's custom scaffold inherits its body
              // text style from the app-level Material. Without it, swipe
              // prompts use Flutter's 48px missing-Material diagnostic style.
              builder: (context, child) => Material(child: WindowFrame(child!)),
              home: Reader(
                key: ValueKey('${mode.key}-$reversed'),
                type: ComicType.local,
                cid: comic.id,
                name: comic.title,
                chapters: chapters,
                history: History.fromModel(model: comic, ep: 1, page: 1),
                author: '',
                tags: [],
              ),
            ),
          );
          await settle();
          final readerContext = tester.element(find.byType(Reader));
          expect(
            DefaultTextStyle.of(readerContext).style.fontSize,
            Theme.of(readerContext).textTheme.bodyMedium!.fontSize,
            reason: 'reader inherits the same body text style as the real app',
          );
          for (
            var i = 0;
            i < 30 &&
                tester.widgetList<RawImage>(find.byType(RawImage)).isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          final dynamic state = tester.state(find.byType(Reader));
          final rect = tester.getRect(find.byType(Reader));
          final vertical = mode.key.endsWith('TopToBottom');
          final rtl = mode.key.endsWith('RightToLeft');
          final nextAtEnd = !rtl != reversed;
          final next = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .1 : .9),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .9 : .1),
                  rect.center.dy,
                );
          final prev = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .9 : .1),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .1 : .9),
                  rect.center.dy,
                );
          expect(state.chapter, 1, reason: '${mode.key}, reverse=$reversed');
          expect(state.page, 1);
          await tester.tapAt(next);
          await settle();
          expect(
            state.page,
            mode.isContinuous ? inInclusiveRange(1, 2) : 2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          for (var step = 0; step < 10 && state.chapter == 1; step++) {
            await tester.tapAt(next);
            await settle();
          }
          expect(state.chapter, 2);
          expect(state.page, 1);
          await tester.tapAt(prev);
          await settle();
          expect(state.chapter, 1);
          expect(
            state.page,
            mode.isContinuous ? inInclusiveRange(1, 2) : 2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          await tester.tapAt(prev);
          await settle();
          expect(state.page, 1);
          await tester.tapAt(prev);
          await settle();
          expect(state.chapter, 1);
          expect(state.page, 1);
          state.toChapter(2);
          await settle();
          state.toPage(2, animate: false);
          await settle();
          await tester.tapAt(next);
          await settle();
          expect(state.chapter, 2);
          expect(
            state.page,
            mode.isContinuous ? inInclusiveRange(1, 2) : 2,
            reason: '${mode.key}, reverse=$reversed, max=${state.maxPage}',
          );
          // Swipes use the same reading order irrespective of reversed taps.
          state.toChapter(1);
          await settle();
          state.toPage(2, animate: false);
          await settle();
          final swipeDistance = mode.isContinuous ? 100.0 : 700.0;
          final forwardSwipe = vertical
              ? Offset(0, -swipeDistance)
              : Offset(rtl ? swipeDistance : -swipeDistance, 0);
          await tester.dragFrom(rect.center, forwardSwipe);
          await settle();
          expect(
            state.chapter,
            2,
            reason: 'forward swipe ${mode.key}, reverse=$reversed',
          );
          state.toPage(1, animate: false);
          await settle();
          await tester.dragFrom(rect.center, -forwardSwipe);
          await settle();
          expect(
            state.chapter,
            1,
            reason: 'backward swipe ${mode.key}, reverse=$reversed',
          );
          if (mode == ReaderMode.continuousTopToBottom && !reversed) {
            // At the bottom of short pages, page 1 may still be partly visible.
            tester.view.physicalSize = const Size(1000, 1800);
            await settle();
            state.toPage(2, animate: false);
            await settle();
            final tall = tester.getRect(find.byType(Reader));
            await tester.tapAt(
              Offset(tall.center.dx, tall.top + tall.height * .9),
            );
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'short final page still advances to next chapter',
            );
            tester.view.physicalSize = const Size(1000, 1000);
            await settle();
          }
          if (mode.isContinuous) {
            // All images fit: there is no elastic scroll extent to trigger
            // the old 160px overscroll chapter transition.
            state.toChapter(1);
            tester.view.physicalSize = vertical
                ? const Size(1000, 3000)
                : const Size(3000, 1000);
            await settle();
            final shortRect = tester.getRect(find.byType(Reader));
            final list = find.byType(ScrollablePositionedList);
            final position = tester
                .state<ScrollableState>(
                  find
                      .descendant(of: list, matching: find.byType(Scrollable))
                      .first,
                )
                .position;
            expect(
              position.maxScrollExtent - position.minScrollExtent,
              closeTo(0, 1),
            );
            await tester.dragFrom(shortRect.center, forwardSwipe * .2);
            await settle();
            expect(
              state.chapter,
              1,
              reason: 'small movements do not switch chapters',
            );
            final cancelled = await tester.startGesture(shortRect.center);
            await cancelled.moveBy(forwardSwipe);
            await cancelled.cancel();
            await settle();
            expect(
              state.chapter,
              1,
              reason: 'cancelled swipes do not switch chapters',
            );
            final firstFinger = await tester.startGesture(
              shortRect.center,
              pointer: 10,
            );
            final secondFinger = await tester.startGesture(
              shortRect.center + const Offset(80, 0),
              pointer: 11,
            );
            await secondFinger.up();
            await firstFinger.moveBy(forwardSwipe);
            await firstFinger.up();
            await settle();
            expect(
              state.chapter,
              1,
              reason: 'a multi-touch gesture does not switch chapters',
            );
            await tester.dragFrom(shortRect.center, forwardSwipe);
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'one ordinary swipe advances a short chapter',
            );
            await tester.dragFrom(shortRect.center, -forwardSwipe);
            await settle();
            expect(state.chapter, 1);

            final nextKey = vertical
                ? LogicalKeyboardKey.arrowDown
                : rtl
                ? LogicalKeyboardKey.arrowLeft
                : LogicalKeyboardKey.arrowRight;
            final prevKey = vertical
                ? LogicalKeyboardKey.arrowUp
                : rtl
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowLeft;
            await tester.sendKeyEvent(nextKey);
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'keyboard continues to the next chapter',
            );
            await tester.sendKeyEvent(prevKey);
            await settle();
            expect(state.chapter, 1);

            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: shortRect.center,
                scrollDelta: const Offset(0, 80),
              ),
            );
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'mouse wheel continues to the next chapter',
            );
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: shortRect.center,
                scrollDelta: const Offset(0, -80),
              ),
            );
            await settle();
            expect(state.chapter, 1);

            final trackpad = await tester.createGesture(
              kind: PointerDeviceKind.trackpad,
            );
            await trackpad.panZoomStart(shortRect.center);
            await trackpad.panZoomUpdate(shortRect.center, pan: forwardSwipe);
            await trackpad.panZoomEnd();
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'trackpad follows the reading axis and direction',
            );
            final backTrackpad = await tester.createGesture(
              kind: PointerDeviceKind.trackpad,
            );
            await backTrackpad.panZoomStart(shortRect.center);
            await backTrackpad.panZoomUpdate(
              shortRect.center,
              pan: -forwardSwipe,
            );
            await backTrackpad.panZoomEnd();
            await settle();
            expect(state.chapter, 1);

            final shortNext = vertical
                ? Offset(
                    shortRect.center.dx,
                    shortRect.top + shortRect.height * (reversed ? .1 : .9),
                  )
                : Offset(
                    shortRect.left + shortRect.width * (nextAtEnd ? .9 : .1),
                    shortRect.center.dy,
                  );
            final shortPrev = vertical
                ? Offset(
                    shortRect.center.dx,
                    shortRect.top + shortRect.height * (reversed ? .9 : .1),
                  )
                : Offset(
                    shortRect.left + shortRect.width * (nextAtEnd ? .1 : .9),
                    shortRect.center.dy,
                  );
            await tester.tapAt(shortNext);
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'edge tap advances a short chapter',
            );
            await tester.tapAt(shortPrev);
            await settle();
            expect(state.chapter, 1);
            tester.view.physicalSize = const Size(1000, 1000);
            await settle();
          }
          // Directory display order must never reverse chapter navigation.
          for (final displayOrder in [
            'source',
            'reverse',
            'titleAscending',
            'titleDescending',
          ]) {
            appdata.settings['comicChapterOrder'] = {
              'direction@local': displayOrder,
            };
            state.toChapter(1);
            await settle();
            expect(state.isFirstChapterOfGroup, isTrue);
            state.toPage(2, animate: false);
            await settle();
            await tester.tapAt(next);
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'next ignores $displayOrder in ${mode.key}',
            );
            expect(state.page, 1);
            expect(state.isLastChapterOfGroup, isTrue);
            await tester.tapAt(prev);
            await settle();
            expect(state.chapter, 1);
            expect(state.page, 2);
            await tester.dragFrom(rect.center, forwardSwipe);
            await settle();
            expect(
              state.chapter,
              2,
              reason: 'swipe ignores $displayOrder in ${mode.key}',
            );
          }
          appdata.settings['comicChapterOrder'] = <String, dynamic>{};
          expect(
            tester.takeException(),
            isNull,
            reason: '${mode.key}, reverse=$reversed',
          );
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => Material(child: WindowFrame(child!)),
              home: const SizedBox(),
            ),
          );
          await settle();
        }
      }
      local.close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );

  for (final mode in ReaderMode.values.where((mode) => mode.isContinuous)) {
    for (final reversed in [false, true]) {
      testWidgets(
        'long boundary images scroll before changing chapters (${mode.key}, reverse=$reversed)',
        (tester) async {
          tester.view.physicalSize = const Size(600, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await ensureTestTranslations();
          final snapshot = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(appdata.toJson())),
          );
          final root = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('long-chapter-direction-'),
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
          for (final entry in {
            'readerMode': mode.key,
            'enablePageAnimation': false,
            'readerTwoPageSpread': false,
            'readerPageMarginEnabled': reversed,
            'readerPageMarginPercent': 15.0,
            'readerScreenPicNumberForLandscape': 1,
            'readerScreenPicNumberForPortrait': 1,
            'limitImageWidth': false,
            'enableTapToTurnPages': true,
            'reverseTapToTurnPages': reversed,
            'enableDoubleTapToZoom': false,
            'enableClockAndBatteryInfoInReader': false,
            'enableTurnPageByVolumeKey': false,
            'recordReadingStatistics': false,
            'removeReadLaterOnComplete': false,
            'webdav': <String>[],
          }.entries) {
            appdata.settings[entry.key] = entry.value;
          }
          final vertical = mode == ReaderMode.continuousTopToBottom;
          final rtl = mode == ReaderMode.continuousRightToLeft;
          final local = LocalManager();
          const chapters = ComicChapters({'ep1': 'First', 'ep2': 'Second'});
          late LocalComic comic;
          await tester.runAsync(() async {
            File(
              '${root.path}/local_path',
            ).writeAsStringSync('${root.path}/local');
            final recorder = ui.PictureRecorder();
            final width = vertical ? 320 : 1920;
            final height = vertical ? 1920 : 320;
            Canvas(recorder).drawRect(
              Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
              Paint()..color = Colors.orange,
            );
            final picture = recorder.endRecording();
            final image = await picture.toImage(width, height);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            image.dispose();
            picture.dispose();
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
              id: 'long-direction',
              title: 'Long direction',
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
            for (var i = 0; i < 3; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 300));
            }
            await _waitForContinuousImages(tester);
          }

          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await settle();
            local.close();
            LocalFavoritesManager().close();
            HistoryManager().close();
            appdata.restoreMemorySnapshot(snapshot);
            await tester.runAsync(() => root.delete(recursive: true));
          });
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
          for (
            var i = 0;
            i < 30 && find.byType(RawImage).evaluate().isEmpty;
            i++
          ) {
            await settle();
          }
          expect(find.byType(RawImage), findsWidgets);
          final dynamic state = tester.state(find.byType(Reader));
          final rect = tester.getRect(find.byType(Reader));
          final nextAtEnd = !rtl != reversed;
          final next = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .1 : .9),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .9 : .1),
                  rect.center.dy,
                );
          final prev = vertical
              ? Offset(
                  rect.center.dx,
                  rect.top + rect.height * (reversed ? .9 : .1),
                )
              : Offset(
                  rect.left + rect.width * (nextAtEnd ? .1 : .9),
                  rect.center.dy,
                );
          ScrollPosition position() => tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: find.byType(ScrollablePositionedList),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position;
          // A page action advances 90% of a viewport inside the first long
          // image, rather than jumping to the next image.
          final beforeStep = position().pixels;
          final viewportStep = position().viewportDimension * .9;
          state.turnPage(forward: true);
          await settle();
          expect(state.chapter, 2);
          expect(state.page, 1);
          expect(position().pixels - beforeStep, closeTo(viewportStep, 1));
          state.toPage(1, animate: false);
          await settle();
          // A real drag puts the first long image partway through the viewport.
          final drag = await tester.startGesture(rect.center);
          await drag.moveBy(
            vertical ? const Offset(0, -250) : Offset(rtl ? 250 : -250, 0),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await drag.up();
          await settle();
          expect(state.chapter, 2);
          expect(state.page, 1);
          final beforeBack = position().pixels;
          expect(beforeBack, greaterThan(position().minScrollExtent + 1));
          await tester.tapAt(prev);
          await settle();
          expect(
            state.chapter,
            2,
            reason:
                'first image is not the chapter start while partially scrolled',
          );
          expect(
            position().pixels,
            lessThan(beforeBack),
            reason: 'backward taps must still scroll the long image',
          );

          tester
              .widget<ScrollablePositionedList>(
                find.byType(ScrollablePositionedList),
              )
              .itemScrollController!
              .jumpTo(index: 1);
          await settle();
          await tester.tapAt(prev);
          await settle();
          expect(state.chapter, 1);
          for (
            var i = 0;
            i < 30 &&
                (state.isLoading ||
                    find.byType(ScrollablePositionedList).evaluate().isEmpty ||
                    find.byType(RawImage).evaluate().isEmpty);
            i++
          ) {
            await settle();
          }
          // Wait for restored image extents before explicitly selecting page 2.
          await _waitForContinuousImages(tester);
          await settle();
          // Test the forward case from the start of the decoded final image.
          state.toPage(2, animate: false);
          await settle();
          expect(state.page, 2);
          expect(position().pixels, lessThan(position().maxScrollExtent - 1));
          for (
            var i = 0;
            i < 20 && position().pixels < position().maxScrollExtent - .5;
            i++
          ) {
            final beforeForward = position().pixels;
            await tester.tapAt(next);
            await settle();
            expect(
              state.chapter,
              1,
              reason: 'the last image still extends beyond the viewport',
            );
            expect(
              position().pixels,
              greaterThan(beforeForward),
              reason: 'forward taps must scroll to the actual image end',
            );
          }
          expect(position().pixels, closeTo(position().maxScrollExtent, .5));
          await tester.tapAt(next);
          await settle();
          expect(
            state.chapter,
            2,
            reason: 'only a tap at the real scroll end advances the chapter',
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 2));
          await settle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
