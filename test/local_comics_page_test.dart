import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'reader_page_margin_test.dart' as fixture;

void main() {
  testWidgets(
    'local library shows size, manages categories and opens a downloaded chapter directly',
    (tester) async {
      await fixture.openReader(tester, 'galleryLeftToRight');
      await tester.pumpWidget(const SizedBox());
      await fixture.settle(tester);
      final local = LocalManager();
      final comic = local.getComics(LocalSortType.name).single;
      await tester.runAsync(() async {
        for (final id in ['first', 'second']) {
          Directory('${comic.baseDir}/$id').createSync();
          File('${comic.baseDir}/1.png').copySync('${comic.baseDir}/$id/1.png');
        }
        await local.add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: '',
            tags: [],
            directory: comic.directory,
            chapters: ComicChapters({
              'first': 'First chapter',
              'second': 'Second chapter',
            }),
            cover: comic.cover,
            comicType: ComicType.local,
            downloadedChapters: ['first', 'second'],
            createdAt: comic.createdAt,
          ),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: const LocalComicsPage(),
        ),
      );
      await fixture.settle(tester);
      expect(find.textContaining('Local · '), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(MenuButton).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Offline');
      await tester.tap(find.text('Save'));
      await fixture.settle(tester);
      expect(local.library.folders.single.name, 'Offline');
      await tester.longPress(find.text('Margin test'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MenuButton).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to folder'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('Offline'),
        ),
      );
      await fixture.settle(tester);
      expect(
        local.library.placements[(comic.id, 0)]?.folder,
        local.library.folders.single.id,
      );
      // Exit selection, filter the category, then open its downloaded chapter.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Offline'));
      await fixture.settle(tester);
      await tester.tap(find.text('Margin test'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second chapter'));
      await fixture.settle(tester);
      expect(tester.widget<Reader>(find.byType(Reader)).initialChapter, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await fixture.settle(tester);
    },
  );
}
