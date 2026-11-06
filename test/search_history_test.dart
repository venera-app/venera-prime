import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/search_history.dart';
import 'package:venera/utils/search_options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'identity separates source/options but not page, JSON validates imports',
    () {
      final entry = SearchHistoryEntry(
        keyword: 'comic',
        sourceKey: 'pica',
        options: ['new'],
        page: 4,
      );
      expect(entry.identity, entry.atPage(2).identity);
      expect(
        entry.identity,
        isNot(
          SearchHistoryEntry(
            keyword: 'comic',
            sourceKey: 'other',
            options: ['new'],
          ).identity,
        ),
      );
      expect(
        entry.identity,
        isNot(
          SearchHistoryEntry(
            keyword: 'comic',
            sourceKey: 'pica',
            options: ['old'],
          ).identity,
        ),
      );
      expect(
        SearchHistoryEntry.decode([
          entry.toJson(),
          entry.atPage(2).toJson(),
          {'keyword': 'invalid'},
        ]).single.page,
        4,
      );
      expect(
        SearchHistoryEntry.fromJson({...entry.toJson(), 'page': -1}),
        isNull,
      );
      expect(
        SearchHistoryEntry.fromJson({
          ...entry.toJson(),
          'options': [3],
        }),
        isNull,
      );
      expect(
        SearchHistoryEntry.decode(
          List.generate(
            60,
            (i) => SearchHistoryEntry(keyword: '$i', sourceKey: '').toJson(),
          ),
        ),
        hasLength(50),
      );
    },
  );
  test(
    'source defaults decode parser strings and normalize multiselect identity',
    () {
      final select = SearchOptions(
        LinkedHashMap.of({'new': 'Newest', 'old': 'Oldest'}),
        'Sort',
        'select',
        '"old"',
      );
      final multi = SearchOptions(
        LinkedHashMap.of({'a': 'A', 'b': 'B'}),
        'Tags',
        'multi-select',
        '["b","a","b"]',
      );
      expect(defaultSearchOptions([select, multi]), ['old', '["a","b"]']);
      expect(validatedSearchOptions([multi], ['["b","a"]']), ['["a","b"]']);
      expect(validatedSearchOptions([select], ['removed']), isNull);
      expect(validatedSearchOptions([multi], ['[1]']), isNull);
      expect(
        searchOptionsSchema([select]),
        isNot(searchOptionsSchema([multi])),
      );
    },
  );
  test(
    'page updates persist, legacy histories and rollback remain compatible',
    () async {
      final temp = await Directory.systemTemp.createTemp('search-records-');
      App.dataPath = temp.path;
      final snapshot =
          jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
      appdata.searchRecords = [];
      appdata.searchHistory = ['legacy'];
      final entry = SearchHistoryEntry(
        keyword: 'comic',
        sourceKey: 'pica',
        options: ['new'],
        page: 4,
      );
      appdata.rememberSearch(entry);
      appdata.updateSearchPage(entry.identity, 2);
      await appdata.flushSearchProgress();
      final saved = jsonDecode(
        await File('${temp.path}/appdata.json').readAsString(),
      );
      expect(saved['searchRecords'][0]['page'], 2);
      expect(saved['searchHistory'], ['comic', 'legacy']);
      expect(appdata.searchHistoryEntries.last.isLegacy, isTrue);
      appdata.restoreMemorySnapshot(saved);
      expect(appdata.searchRecords.single.page, 2);
      appdata.restoreMemorySnapshot({...saved, 'searchRecords': null});
      expect(appdata.searchHistoryEntries.every((e) => e.isLegacy), isTrue);
      // Many source/filter variants must not evict unrelated keyword history.
      for (var i = 0; i < 50; i++) {
        appdata.rememberSearch(
          SearchHistoryEntry(
            keyword: 'comic',
            sourceKey: 'pica',
            options: ['$i'],
          ),
        );
      }
      await appdata.flushSearchProgress();
      final bothHistories = jsonDecode(
        await File('${temp.path}/appdata.json').readAsString(),
      );
      appdata.restoreMemorySnapshot(bothHistories);
      expect(appdata.searchRecords, hasLength(50));
      expect(appdata.searchHistory, ['comic', 'legacy']);
      appdata.restoreMemorySnapshot(snapshot);
      await temp.delete(recursive: true);
    },
  );
  test('sync preserves search records omitted by older snapshots', () {
    final snapshot =
        jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
    try {
      final entry = SearchHistoryEntry(
        keyword: 'comic',
        sourceKey: 'pica',
        options: ['new'],
        page: 4,
      );
      appdata.searchRecords = [entry];

      appdata.syncData({'settings': <String, dynamic>{}}, persist: false);
      expect(appdata.searchRecords.single.identity, entry.identity);
      expect(appdata.searchRecords.single.page, 4);

      appdata.syncData({
        'settings': <String, dynamic>{},
        'searchRecords': <dynamic>[],
      }, persist: false);
      expect(appdata.searchRecords, isEmpty);
    } finally {
      appdata.restoreMemorySnapshot(snapshot);
    }
  });
}
