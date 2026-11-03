import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/search_results_list.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);
  setUp(() => appdata.settings['comicListDisplayMode'] = 'paging');
  Widget host(SearchResultsList list) =>
      MaterialApp(home: Scaffold(body: list));
  testWidgets(
    'numbered restore requests P4 directly and records going back to P2',
    (tester) async {
      final requests = <int>[];
      final visible = <int>[];
      await tester.pumpWidget(
        host(
          SearchResultsList(
            header: const SizedBox(),
            initialPage: 4,
            onVisiblePage: visible.add,
            loadPage: (page) async {
              requests.add(page);
              return const Res(<Comic>[], subData: 8);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, [4]);
      expect(visible, [4]);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(requests, [4, 3, 2]);
      expect(visible.last, 2);
    },
  );
  testWidgets('cursor restoration replays tokens, stops at source end', (
    tester,
  ) async {
    final requests = <String?>[];
    final visible = <int>[];
    await tester.pumpWidget(
      host(
        SearchResultsList(
          header: const SizedBox(),
          initialPage: 4,
          onVisiblePage: visible.add,
          loadNext: (cursor) async {
            requests.add(cursor);
            return Res(<Comic>[], subData: cursor == null ? 'second' : null);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [null, 'second']);
    expect(visible, [2]);
    expect(
      find.text(
        'The saved page is no longer available. Showing the last page.',
      ),
      findsOneWidget,
    );
  });
  testWidgets('cursor replay retries failed token without advancing history', (
    tester,
  ) async {
    final requests = <String?>[];
    final visible = <int>[];
    var fail = true;
    await tester.pumpWidget(
      host(
        SearchResultsList(
          header: const SizedBox(),
          initialPage: 3,
          onVisiblePage: visible.add,
          loadNext: (cursor) async {
            requests.add(cursor);
            if (cursor == 'second' && fail) return const Res.error('offline');
            return Res(
              <Comic>[],
              subData: cursor == null
                  ? 'second'
                  : cursor == 'second'
                  ? 'third'
                  : null,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(visible, isEmpty);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(requests, [null, 'second', 'second', 'third']);
    expect(visible, [3]);
  });
  testWidgets(
    'cancel ignores in-flight response and leaves retry available on root route',
    (tester) async {
      final pending = Completer<Res<List<Comic>>>();
      final visible = <int>[];
      await tester.pumpWidget(
        host(
          SearchResultsList(
            header: const SizedBox(),
            initialPage: 4,
            onVisiblePage: visible.add,
            loadNext: (_) => pending.future,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      pending.complete(const Res(<Comic>[], subData: 'second'));
      await tester.pumpAndSettle();
      expect(visible, isEmpty);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'continuous progress follows visible grids, not prefetched pages, and moves backwards',
    (tester) async {
      appdata.settings['comicListDisplayMode'] = 'continuous';
      appdata.settings['showFavoriteStatusOnTile'] = false;
      appdata.settings['showHistoryStatusOnTile'] = false;
      final requests = <int>[];
      final visible = <int>[];
      await tester.pumpWidget(
        host(
          SearchResultsList(
            header: const SizedBox(),
            initialPage: 4,
            onVisiblePage: visible.add,
            loadPage: (page) async {
              requests.add(page);
              return Res(
                List.generate(
                  12,
                  (i) => Comic(
                    'Comic $page-$i',
                    'file://${Directory.current.path}/assets/app_icon.png',
                    '$page-$i',
                    '',
                    [],
                    '',
                    'test',
                    null,
                    null,
                  ),
                ),
                subData: 6,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(visible, [4]);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      // Reach the first page's bottom cache region: the next page is built
      // before it becomes the top visible page.
      for (var i = 0; i < 30 && !requests.contains(5); i++) {
        scroll.jumpTo((scroll.pixels + 80).clamp(0, scroll.maxScrollExtent));
        await tester.pumpAndSettle();
      }
      expect(requests, contains(5));
      expect(visible.last, 4);
      for (var i = 0; i < 30 && visible.last != 5; i++) {
        scroll.jumpTo((scroll.pixels + 80).clamp(0, scroll.maxScrollExtent));
        await tester.pumpAndSettle();
      }
      expect(visible.last, 5);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(visible.last, 4);
      await tester.tap(find.text('Load previous page'));
      await tester.pumpAndSettle();
      expect(visible.last, 3);
      await tester.tap(find.text('Load previous page'));
      await tester.pumpAndSettle();
      expect(visible.last, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    },
  );
}
