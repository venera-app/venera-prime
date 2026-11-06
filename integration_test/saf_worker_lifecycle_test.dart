import 'dart:isolate';
import 'dart:io';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'SAF JNI workers can retire without aborting the application',
    (_) async {
      await Future.wait(
        List.generate(
          12,
          (_) => Isolate.run(() {
            // Resolving an unavailable path still crosses JNI, with no storage grant.
            AndroidDirectory.fromPathSync(
              'android://primary:prime-saf-missing',
            );
          }),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 80));
      expect(true, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isAndroid,
  );
}
