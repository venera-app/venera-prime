import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

const longOption =
    'A very long server description with a full URL https://example.invalid/very/long/path';

class _Source implements ComicSource {
  @override
  String get key => 'layout-test';
  @override
  String get name => 'Layout test source';
  @override
  String get version => '1.0.0';
  @override
  String get url => 'https://example.invalid/source.js';
  @override
  final data = <String, dynamic>{};
  @override
  Map<String, Map<String, dynamic>> getSettingsDynamic() => {
    'server': {
      'type': 'select',
      'title': 'Server',
      'default': 'long',
      'options': [
        {'value': 'long', 'text': longOption},
      ],
    },
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('long source option fits a narrow page and its menu opens', (
    tester,
  ) async {
    await AppTranslation.init();
    ComicSourceManager().add(_Source());
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: ComicSourcePage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(Select));
    await tester.tap(find.byType(Select));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The menu retains the full text even though the closed value is truncated.
    expect(find.text(longOption), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
}
