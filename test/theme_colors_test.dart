import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/theme_colors.dart';
import 'package:venera/pages/settings/theme_color_dialog.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);
  test('custom RGB is opaque and invalid persisted values fall back', () {
    expect(resolveThemeColor('custom', 0x123456), const Color(0xff123456));
    expect(resolveThemeColor('custom', 'bad'), Colors.blue);
    expect(resolveThemeColor('teal', null), Colors.teal);
    expect(parseThemeHex(' #aB12eF '), const Color(0xffab12ef));
    expect(parseThemeHex('12345'), isNull);
    expect(parseThemeHex('#GG1234'), isNull);
  });
  test(
    'custom color and selection survive settings serialization to disk',
    () async {
      final root = await Directory.systemTemp.createTemp('theme-settings-');
      App.dataPath = root.path;
      try {
        appdata.settings['color'] = 'custom';
        appdata.settings['customThemeColor'] = 0xff123456;
        await appdata.saveData(false);
        final saved = jsonDecode(
          await File('${root.path}/appdata.json').readAsString(),
        )['settings'];
        expect(saved['color'], 'custom');
        expect(
          resolveThemeColor(saved['color'], saved['customThemeColor']),
          const Color(0xff123456),
        );
      } finally {
        appdata.settings['color'] = 'system';
        appdata.settings['customThemeColor'] = 0xff2196f3;
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets('custom dialog validates HEX and returns selected RGB', (
    tester,
  ) async {
    Color? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showDialog<Color>(
                context: context,
                builder: (_) =>
                    const ThemeColorDialog(initialColor: Colors.blue),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'broken');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '#123456');
    await tester.pump();
    expect(tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.value), [
      18,
      52,
      86,
    ]);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(selected, const Color(0xff123456));
  });
}
