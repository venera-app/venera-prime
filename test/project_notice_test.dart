import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/project_notice.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late dynamic oldLanguage;
  setUpAll(AppTranslation.init);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('prime-notice-');
    oldLanguage = appdata.settings['language'];
    App.dataPath = root.path;
  });
  tearDown(() async {
    appdata.settings['language'] = oldLanguage;
    await root.delete(recursive: true);
  });

  test(
    'existing users need the new receipt; acknowledgement persists independently of app data',
    () async {
      File(
        '${root.path}/appdata.json',
      ).writeAsStringSync('{"settings": {"firstUse": false}}');
      expect(await ProjectNoticeReceipt.isAcknowledged(), isFalse);
      await ProjectNoticeReceipt.acknowledge();
      expect(await ProjectNoticeReceipt.isAcknowledged(), isTrue);
      File('${root.path}/appdata.json').writeAsStringSync('{}');
      expect(await ProjectNoticeReceipt.isAcknowledged(), isTrue);
      File('${root.path}/project-notice-receipt').writeAsStringSync('invalid');
      expect(await ProjectNoticeReceipt.isAcknowledged(), isFalse);
    },
  );

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    testWidgets(
      '$language notice scrolls at narrow width and only acknowledgement dismisses it',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appdata.settings['language'] = language;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showProjectNotice(context, acknowledgementRequired: true),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Community and feedback'.tl), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Community and feedback'.tl)).dy,
          lessThan(
            tester
                .getTopLeft(find.text('How this project is maintained'.tl))
                .dy,
          ),
        );
        await tester.tapAt(const Offset(2, 2));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(ProjectNoticeDialog), findsOneWidget);
        expect(
          await tester.runAsync(ProjectNoticeReceipt.isAcknowledged),
          isFalse,
        );
        final button = find.byKey(const Key('project-notice-confirm'));
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(640));
        await tester.scrollUntilVisible(
          find.text('Contributing'.tl),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(button);
        for (
          var i = 0;
          i < 30 && find.byType(ProjectNoticeDialog).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(find.byType(ProjectNoticeDialog), findsNothing);
        expect(
          await tester.runAsync(ProjectNoticeReceipt.isAcknowledged),
          isTrue,
        );
      },
    );
  }

  testWidgets('viewing from About does not mark the startup notice as read', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showProjectNotice(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-notice-confirm')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(ProjectNoticeReceipt.isAcknowledged), isFalse);
  });
}
