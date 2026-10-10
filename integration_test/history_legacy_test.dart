import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/translations.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device: legacy import, history search and dated scrollbar', (
    tester,
  ) async {
    await App.init();
    await App.initComponents();
    await AppTranslation.init();
    appdata.settings['webdav'] = [];
    appdata.settings['blockedWords'] = [];
    appdata.settings['language'] = 'en-US';
    final cover = File('${App.dataPath}/history-fixture.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNoWHAAK2IYWhIA03p4AStH0poAAAAASUVORK5CYII=',
        ),
      );
    HistoryManager().clearHistory();
    for (var i = 0; i < 160; i++) {
      await CacheManager().writeCache(
        '${cover.path}@local@history-$i',
        cover.readAsBytesSync(),
      );
      HistoryManager().addHistory(
        History.fromMap({
          'id': 'history-$i',
          'type': 0,
          'title': 'History fixture $i',
          'subtitle': 'Device regression',
          'cover': cover.path,
          'time': DateTime(
            2026,
            10,
            10,
          ).subtract(Duration(days: i)).millisecondsSinceEpoch,
          'ep': 1,
          'page': 1,
        }),
      );
    }
    final manager = LocalFavoritesManager();
    final folders = List.generate(64, (i) => 'Legacy ${63 - i}');
    for (final folder in folders) {
      manager.createFolder(folder);
    }
    manager.close();
    final db = sqlite3.open('${App.dataPath}/local_favorite.db');
    db.execute('DELETE FROM folder_order');
    for (final folder in folders.take(32)) {
      db.execute('INSERT INTO folder_order VALUES (?, 0)', [folder]);
    }
    db.dispose();
    final archive = Archive();
    for (final name in ['history.db', 'local_favorite.db']) {
      archive.addFile(
        ArchiveFile.bytes(
          name,
          File('${App.dataPath}/$name').readAsBytesSync(),
        ),
      );
    }
    archive.addFile(
      ArchiveFile.bytes(
        'appdata.json',
        utf8.encode(jsonEncode(appdata.toJson())),
      ),
    );
    final backup = File('${App.cachePath}/legacy.venera')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    await importAppData(backup);
    expect(manager.folderNames, folders);
    manager.close();
    await manager.init();
    expect(manager.folderNames, folders);
    print('DEVICE_LEGACY_IMPORT_PASS: 64 folders, missing/tied order, reopen');

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const HistoryPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsNothing);
    final search = tester.widget<SliverSearchBar>(find.byType(SliverSearchBar));
    expect(search.embedded, isTrue);
    expect(tester.takeException(), isNull);
    print('DEVICE_HISTORY_LAYOUT_READY');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 8)),
    );
    final scrollbar = tester.widget<AppScrollBar>(find.byType(AppScrollBar));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.arrow_drop_down)),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(scrollbar.controller.offset, greaterThan(0));
    final label = scrollbar.dragLabelBuilder!()!;
    expect(find.text(label), findsOneWidget);
    final tiles = tester.widgetList<ComicTile>(find.byType(ComicTile)).where((
      tile,
    ) {
      final rect = tester.getRect(find.byWidget(tile));
      final searchBottom = tester.getBottomLeft(find.byType(TextField)).dy;
      return rect.bottom > searchBottom &&
          rect.top <
              tester.view.physicalSize.height / tester.view.devicePixelRatio;
    }).toList();
    expect(
      tiles.map(
        (tile) => (tile.comic as History).lastReadTime.split(' ').first,
      ),
      contains(label),
    );
    print('DEVICE_HISTORY_DRAG_READY: $label');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 8)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text(label), findsNothing);
    await tester.enterText(find.byType(TextField), 'History fixture 159');
    await tester.pumpAndSettle();
    expect(find.text('History fixture 159'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    print('DEVICE_HISTORY_SEARCH_PASS');
    await tester.pumpWidget(const SizedBox());
    App.closeComponents();
  });
}
