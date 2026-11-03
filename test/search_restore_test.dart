import 'dart:collection';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/search_history.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/search_options.dart';
import 'package:venera/utils/translations.dart';

class Source implements ComicSource {
  @override
  String get key => 'search-test';
  @override
  String get name => 'Test source';
  final calls = <(String, int, List<String>)>[];
  final definitions = [
    SearchOptions(
      LinkedHashMap.of({'new': 'Newest', 'old': 'Oldest'}),
      'Sort',
      'select',
      'new',
    ),
  ];
  @override
  SearchPageData get searchPageData =>
      SearchPageData(definitions, (word, page, options) async {
        calls.add((word, page, List.of(options)));
        return const Res(<Comic>[], subData: 10);
      }, null);
  @override
  Map<String, Map<String, String>>? get translations => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(AppTranslation.init);
  late Directory temp;
  late Source source;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('search-restore-');
    App.dataPath = temp.path;
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.searchRecords = [];
    appdata.searchHistory = [];
    source = Source();
    ComicSourceManager().add(source);
  });
  tearDown(() async {
    await appdata.flushSearchProgress();
    ComicSourceManager().remove(source.key);
    await temp.delete(recursive: true);
  });
  for (final changed in [false, true]) {
    testWidgets('restores keyword/options/page with changed schema=$changed', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final entry = SearchHistoryEntry(
          keyword: 'saved word',
          sourceKey: source.key,
          options: ['old'],
          schema: changed
              ? 'obsolete'
              : searchOptionsSchema(source.definitions),
          page: 4,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: SearchResultPage(
              text: entry.keyword,
              sourceKey: source.key,
              options: entry.options,
              historyEntry: entry,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await appdata.saveData(false);
        expect(source.calls.single.$1, 'saved word');
        expect(source.calls.single.$2, changed ? 1 : 4);
        expect(source.calls.single.$3, [changed ? 'new' : 'old']);
        expect(appdata.searchRecords.single.labels, [
          'Sort: ${changed ? 'Newest' : 'Oldest'}',
        ]);
        await tester.pumpWidget(const SizedBox());
        await appdata.saveData(false);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
