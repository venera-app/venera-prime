import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/home_page.dart';
import 'support/test_translations.dart';

void main() {
  for (final width in [360.0, 1100.0]) {
    testWidgets(
      'home folder returns directly with toolbar and system back at $width',
      (tester) async {
        await ensureTestTranslations();
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('home-folder-'),
        ))!;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
        appdata.settings['webdav'] = [];
        appdata.settings['favorites'] = <String>[];
        appdata.implicitData.remove('favoriteFolder');
        final manager = LocalFavoritesManager();
        manager.close();
        await tester.runAsync(() => manager.init());
        manager.createFolder('Home folder');
        final layout = HomeLayout.fromJson(null)..addFolder('Home folder');
        layout.hidden.addAll(HomeLayout.titles.keys);
        appdata.settings['homeLayout'] = layout.toJson();
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => WindowFrame(child!),
              home: const Scaffold(body: HomePage()),
            ),
          );
          await tester.pumpAndSettle();
          for (final toolbar in [true, false]) {
            await tester.tap(find.text('Home folder'));
            await tester.pumpAndSettle();
            expect(find.byType(FavoritesPage), findsOneWidget);
            expect(find.byTooltip('Back'), findsOneWidget);
            if (toolbar) {
              await tester.tap(find.byTooltip('Search'));
              await tester.pumpAndSettle();
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
              expect(find.byType(FavoritesPage), findsOneWidget);
              expect(find.byTooltip('Back'), findsOneWidget);
              await tester.tap(find.byTooltip('Back'));
            } else {
              await tester.binding.handlePopRoute();
            }
            await tester.pumpAndSettle();
            expect(find.byType(FavoritesPage), findsNothing);
            expect(find.byType(HomePage), findsOneWidget);
            expect(find.text('Home folder'), findsOneWidget);
          }
          await tester.pump(const Duration(seconds: 2));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => appdata.saveData(false));
          manager.close();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }
}
