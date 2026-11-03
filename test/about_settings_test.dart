import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const description =
      'Venera Prime is a free and open-source app for comic reading.';
  const telegramLabels = {
    'zh-CN': 'Venera Prime Telegram 群',
    'zh-TW': 'Venera Prime Telegram 群',
    'en-US': 'Venera Prime Telegram group',
  };

  setUpAll(AppTranslation.init);

  for (final locale in ['zh-CN', 'zh-TW', 'en-US']) {
    for (final width in [320.0, 800.0]) {
      testWidgets(
        'about $locale at width $width has centered, padded description',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final previousLanguage = appdata.settings['language'];
          addTearDown(() => appdata.settings['language'] = previousLanguage);
          appdata.settings['language'] = locale;
          final tasks = BackgroundTasks.instance;
          tasks.clearFinished();
          var opened = 0;
          tasks.start('app-update-check', 'Check for updates')
            ..resultLabel = 'View update'
            ..onOpenResult = () {
              opened++;
            }
            ..finish();
          addTearDown(tasks.clearFinished);
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const Scaffold(body: AboutSettings()),
            ),
          );
          await tester.pumpAndSettle();
          final translated = description.tl;
          if (locale.startsWith('zh')) expect(translated, isNot(description));
          final finder = find.text(translated);
          expect(finder, findsOneWidget);
          expect(tester.widget<Text>(finder).textAlign, TextAlign.center);
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(24));
          expect(width - rect.right, closeTo(rect.left, 0.01));
          expect(tester.takeException(), isNull);
          expect(find.text('New version available'.tl), findsOneWidget);
          expect(find.text('Check'.tl), findsNothing);
          await tester.tap(find.text('View update'.tl));
          await tester.pump();
          expect(opened, 1);
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(
            find.text(telegramLabels[locale]!),
            100,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text(telegramLabels[locale]!), findsOneWidget);
          expect(find.text('Telegram'), findsNothing);
          await tester.scrollUntilVisible(
            find.text('Upstream project Telegram group'.tl),
            100,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            find.text('Upstream project Telegram group'.tl),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
