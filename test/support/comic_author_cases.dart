import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/window_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/comic_author_link.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/translations.dart';

class _AuthorSource implements ComicSource {
  @override
  final String key = 'author-link-fixture';
  bool supported = true;
  PageJumpTarget? Function(String, String)? handler;
  String? query;
  @override
  get handleClickTagEvent => handler;
  @override
  String get name => 'Author search fixture';
  @override
  bool get enableTagsSuggestions => false;
  @override
  bool get enableTagsTranslate => false;
  @override
  SearchPageData? get searchPageData => !supported
      ? null
      : SearchPageData(null, (keyword, page, options) async {
          query = keyword;
          return const Res<List<Comic>>([], subData: 1);
        }, null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void registerComicAuthorTests({bool device = false}) {
  testWidgets('author link searches current source and respects tag rules', (
    tester,
  ) async {
    await AppTranslation.init();
    if (!device) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
    }
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('author-link-'),
    ))!;
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings['webdav'] = [];
    appdata.settings['autoAddLanguageFilter'] = 'none';
    appdata.settings['convertTraditionalToSimplified'] = false;
    final source = _AuthorSource();
    ComicSourceManager().add(source);
    const author = '作者 A:B / C';
    ComicDetails details({bool tags = false, String subtitle = author}) =>
        ComicDetails.fromJson({
          'title': 'Author fixture',
          'subtitle': subtitle,
          'cover': '',
          'tags': tags
              ? {
                  '作者': [author],
                }
              : <String, dynamic>{},
          'sourceKey': source.key,
          'comicId': 'author-fixture',
        });
    Future<void> show(ComicDetails comic) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Scaffold(
            appBar: AppBar(title: const Text('Author fixture')),
            body: Center(child: ComicAuthorLink(comic: comic)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapAndExpect(String query) async {
      await tester.tap(find.byType(SelectableText));
      await tester.pumpAndSettle();
      final page = tester.widget<SearchResultPage>(
        find.byType(SearchResultPage),
      );
      expect(page.sourceKey, source.key);
      expect(page.text, query);
      expect(source.query, query);
      // Alternate real IO and frame pumps to drain atomic search-history writes.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    }

    try {
      await show(details());
      await tapAndExpect(author);
      source.handler = (namespace, tag) {
        expect(namespace, '作者');
        expect(tag, author);
        return PageJumpTarget(source.key, 'search', {'text': 'artist:"$tag"'});
      };
      await show(details(tags: true));
      await tapAndExpect('artist:"$author"');
      if (device) {
        print('DEVICE_AUTHOR_SEARCH_READY');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 8)),
        );
      }
      source.handler = (_, _) => null;
      await show(details(tags: true));
      await tapAndExpect(author);
      expect(
        authorTagTarget(source, 'Artist', author)?.attributes?['text'],
        author,
      );
      expect(authorTagTarget(source, 'genre', 'drama'), isNull);
      source.handler = null;
      source.supported = false;
      await show(details());
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).onTap,
        isNull,
      );
      source.supported = true;
      await show(details(subtitle: '   '));
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).onTap,
        isNull,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      ComicSourceManager().remove(source.key);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
