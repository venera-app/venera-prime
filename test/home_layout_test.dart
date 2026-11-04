import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/pages/settings/home_layout_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  test(
    'favorite modules and compact preference persist and can be removed',
    () {
      final layout = HomeLayout.fromJson(null)
        ..addFolder('My favorites')
        ..compact = true;
      layout.addFolder('My favorites');
      expect(layout.order.where((id) => id == 'folder:My favorites').length, 1);
      final restored = HomeLayout.fromJson(layout.toJson());
      expect(restored.compact, isTrue);
      expect(restored.folders['folder:My favorites'], 'My favorites');
      restored.hidden.add('folder:My favorites');
      restored.removeFolder('folder:My favorites');
      expect(restored.order, HomeLayout.titles.keys.toList());
      expect(restored.hidden, isEmpty);
    },
  );

  test('defaults preserve all existing modules in order', () {
    final layout = HomeLayout.fromJson(null);
    expect(layout.order, HomeLayout.titles.keys.toList());
    expect(layout.hidden, isEmpty);
  });

  test(
    'invalid and duplicate ids are ignored; missing modules are appended',
    () {
      final layout = HomeLayout.fromJson({
        'order': ['statistics', 'statistics', 4, 'unknown'],
        'hidden': ['history', 'unknown', false],
      });
      expect(layout.order.first, 'statistics');
      expect(layout.order.length, HomeLayout.titles.length);
      expect(layout.hidden, {'history'});
      expect(HomeLayout.fromJson(layout.toJson()).toJson(), layout.toJson());
      expect(
        HomeLayout.fromJson({'order': false, 'hidden': 42}).order,
        HomeLayout.titles.keys.toList(),
      );
    },
  );

  testWidgets('narrow layout toggles, reorders, persists and resets', (
    tester,
  ) async {
    await AppTranslation.init();
    final snapshot = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(appdata.toJson())),
    );
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('prime-home-layout-'),
    ))!;
    App.dataPath = root.path;
    appdata.settings['webdav'] = [];
    appdata.settings['homeLayout'] = <String, dynamic>{};
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(const MaterialApp(home: HomeLayoutPage()));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('toggle-search')));
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(HomeLayout.fromJson(appdata.settings['homeLayout']).hidden, {
        'search',
      });
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byType(SwitchListTile));
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(
        HomeLayout.fromJson(appdata.settings['homeLayout']).compact,
        isTrue,
      );
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      await tester.runAsync(() async {
        list.onReorder(0, 3);
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      final saved = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(saved['settings']['homeLayout']['order'][2], 'search');
      final synced = jsonDecode(
        File('${root.path}/syncdata.json').readAsStringSync(),
      );
      expect(synced['settings']['homeLayout'], saved['settings']['homeLayout']);
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.restore));
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(
        HomeLayout.fromJson(appdata.settings['homeLayout']).hidden,
        isEmpty,
      );
      expect(
        HomeLayout.fromJson(appdata.settings['homeLayout']).order,
        HomeLayout.titles.keys.toList(),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      appdata.restoreMemorySnapshot(snapshot);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
