import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  testWidgets('embedded search omits back button and duplicate safe area', (
    tester,
  ) async {
    String query = '';
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 30)),
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverSearchBar(
                  controller: SearchBarController(),
                  embedded: true,
                  onChanged: (value) => query = value,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackButton), findsNothing);
    expect(
      tester
          .widget<SliverPersistentHeader>(find.byType(SliverPersistentHeader))
          .delegate
          .maxExtent,
      52,
    );
    await tester.enterText(find.byType(TextField), 'saved comic');
    expect(query, 'saved comic');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.clear));
    expect(query, '');
  });
  testWidgets('scrollbar drags and shows a label only during dragging', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppScrollBar(
            controller: controller,
            dragLabelBuilder: () => '2026-10-10',
            child: ListView.builder(
              controller: controller,
              itemExtent: 80,
              itemCount: 100,
              itemBuilder: (_, i) => Text('$i'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026-10-10'), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.arrow_drop_down)),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    expect(find.text('2026-10-10'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('2026-10-10'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
