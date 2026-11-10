import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/translations.dart';

class _Source implements ComicSource {
  @override
  String get key => 'navigation-test';
  @override
  String get name => 'Navigation test';
  @override
  LinkHandler get linkHandler => LinkHandler(['example.org'], (_) => '123');
  @override
  get loadComicInfo =>
      (String _) async => const Res<ComicDetails>.error('Offline test');
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('comic link appears above an existing root reader route', (
    tester,
  ) async {
    await AppTranslation.init();
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('link-navigation-'),
    ))!;
    App.dataPath = root.path;
    App.cachePath = root.path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );

    await tester.runAsync(() async {
      await LocalManager().init();
      await LocalFavoritesManager().init();
      await HistoryManager().init();
    });
    ComicSourceManager().add(_Source());
    final inner = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = inner;
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Navigator(
            key: inner,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      App.rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Existing reader')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing reader'), findsOneWidget);
      expect(
        await handleAppLink(Uri.parse('https://example.org/comic/123')),
        isTrue,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ComicPage), findsOneWidget);
      expect(find.text('Existing reader'), findsNothing);
      expect(
        inner.currentState!.canPop(),
        isFalse,
        reason: 'Do not hide the new page in the home navigator',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      App.mainNavigatorKey = null;
      ComicSourceManager().remove('navigation-test');
      LocalManager().close();
      LocalFavoritesManager().close();
      HistoryManager().close();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
