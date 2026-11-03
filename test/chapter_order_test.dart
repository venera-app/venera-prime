import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/chapter_order_button.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/chapter_order.dart';
import 'support/test_translations.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/chapter_navigation.dart';

void main() {
  test(
    'mixed chapter spellings share ascending and descending numeric order',
    () {
      const chapters = ComicChapters({
        'ten': '第10话',
        'two': '2',
        'one': '第 １ 話',
        'three': 'Chapter 3',
        'also-one': '第一话',
      });
      final indexes = List.generate(chapters.length, (i) => i);
      expect(ChapterOrder.titleAscending.apply(indexes, chapters.titles), [
        2,
        4,
        1,
        3,
        0,
      ]);
      expect(ChapterOrder.titleDescending.apply(indexes, chapters.titles), [
        0,
        3,
        1,
        2,
        4,
      ]);
      expect(ChapterOrder.source.apply(indexes, chapters.titles), indexes);
      expect(
        ChapterOrder.reverse.apply(indexes, chapters.titles),
        indexes.reversed.toList(),
      );
      expect(chapters.ids, ['ten', 'two', 'one', 'three', 'also-one']);
      expect(ChapterOrder.titleAscending.apply([0, 3], chapters.titles), [
        3,
        0,
      ]);
    },
  );

  test('source chronology stays separate from directory display order', () {
    const chapters = ComicChapters({
      'ten': 'Chapter 10',
      'two': 'Chapter 2',
      'one': 'Chapter 1',
    });
    const sequence = ChapterSequence(descending: true);
    for (final displayOrder in ChapterOrder.values) {
      displayOrder.apply([0, 1, 2], chapters.titles);
      expect(sequence.adjacent(chapters, 3, forward: true), 2);
      expect(sequence.adjacent(chapters, 2, forward: true), 1);
      expect(sequence.adjacent(chapters, 1, forward: true), isNull);
      expect(sequence.adjacent(chapters, 2, forward: false), 3);
      expect(sequence.lastChapter(chapters), 1);
    }
    expect(ChapterOrder.titleAscending.apply([0, 1, 2], chapters.titles), [
      2,
      1,
      0,
    ]);
    expect(chapters.ids.toList(), ['ten', 'two', 'one']);
    expect(const ChapterSequence().lastChapter(chapters), 3);
  });

  test('arbitrary chapter titles keep source group boundaries', () {
    const chapters = ComicChapters.grouped({
      'empty': {},
      'a': {'end': '结局', 'extra': '番外', 'start': '序章'},
      'b': {'other': '另一卷'},
    });
    for (final descending in [false, true]) {
      final sequence = ChapterSequence(descending: descending);
      final first = descending ? 3 : 1;
      final last = descending ? 1 : 3;
      expect(sequence.adjacent(chapters, first, forward: false), isNull);
      expect(sequence.adjacent(chapters, first, forward: true), 2);
      expect(sequence.adjacent(chapters, last, forward: true), isNull);
      expect(sequence.adjacent(chapters, 4, forward: false), isNull);
      expect(sequence.adjacent(chapters, 4, forward: true), isNull);
    }
    expect(const ChapterSequence().adjacent(null, 1, forward: true), isNull);
  });

  testWidgets('chapter menu saves choice per comic and source and reloads it', (
    tester,
  ) async {
    await ensureTestTranslations();
    final snapshot = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(appdata.toJson())),
    );
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('chapter-order-'),
    ))!;
    App.dataPath = root.path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    appdata.settings['webdav'] = [];
    appdata.settings['comicChapterOrder'] = <String, dynamic>{};
    appdata.settings['comicChapterReadingOrder'] = <String, dynamic>{};
    var changes = 0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => Material(child: WindowFrame(child!)),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                ChapterReadingOrderButton(
                  comicId: 'comic',
                  sourceKey: 'source',
                  onChanged: () => changes++,
                ),
                ChapterOrderButton(
                  comicId: 'comic',
                  sourceKey: 'source',
                  onChanged: () => changes++,
                ),
              ],
            ),
          ),
        ),
      );
      DataSync();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('chapter-order')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<ChapterOrder> &&
              widget.value == ChapterOrder.titleAscending,
        ),
      );
      await tester.pumpAndSettle();
      final dataFile = File('${root.path}/appdata.json');
      Map<String, dynamic>? savedSettings() {
        try {
          return Map<String, dynamic>.from(
            jsonDecode(dataFile.readAsStringSync())['settings'],
          );
        } on FileSystemException {
          return null;
        }
      }

      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (savedSettings()?['comicChapterOrder']?['comic@source'] ==
            'titleAscending') {
          break;
        }
      }
      await tester.pump(const Duration(seconds: 1));
      expect(changes, 1);
      expect(
        ChapterOrder.forComic('comic', 'source'),
        ChapterOrder.titleAscending,
      );
      expect(ChapterOrder.forComic('other', 'source'), ChapterOrder.source);
      expect(ChapterOrder.forComic('comic', 'other'), ChapterOrder.source);
      final saved = savedSettings()!;
      expect(saved['comicChapterOrder']['comic@source'], 'titleAscending');
      appdata.settings['comicChapterOrder'] = saved['comicChapterOrder'];
      await tester.tap(find.byKey(const Key('chapter-order')));
      await tester.pumpAndSettle();
      final checked = tester
          .widgetList<CheckedPopupMenuItem<ChapterOrder>>(
            find.byType(CheckedPopupMenuItem<ChapterOrder>),
          )
          .where((item) => item.checked);
      expect(checked.single.value, ChapterOrder.titleAscending);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chapter-reading-order')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<ChapterReadingOrder> &&
              widget.value == ChapterReadingOrder.reverse,
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        final writing = root.listSync().any(
          (file) => file.path.endsWith('.tmp') || file.path.endsWith('.bak'),
        );
        if (!writing &&
            savedSettings()?['comicChapterReadingOrder']?['comic@source'] ==
                'reverse') {
          break;
        }
      }
      expect(
        savedSettings()?['comicChapterReadingOrder']?['comic@source'],
        'reverse',
      );
      expect(
        ChapterReadingOrder.forComic('comic', 'source'),
        ChapterReadingOrder.reverse,
      );
      expect(
        ChapterReadingOrder.forComic('other', 'source'),
        ChapterReadingOrder.automatic,
      );
      expect(
        ChapterOrder.forComic('comic', 'source'),
        ChapterOrder.titleAscending,
      );
      expect(changes, 2);
    } finally {
      await tester.pumpWidget(const SizedBox());
      appdata.restoreMemorySnapshot(snapshot);
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
