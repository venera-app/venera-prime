import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera/utils/io.dart' as io;
import '../test/archive_security_test.dart' as archive;
import '../test/download_retry_test.dart' as downloads;
import '../test/epub_export_test.dart' as epub;
import '../test/image_processing_safety_test.dart' as image_safety;
import '../test/local_library_test.dart' as local_library;
import '../test/support/data_sync_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Archive', archive.main);
  group('Downloads', downloads.main);
  group('EPUB', epub.main);
  group('Image processing', image_safety.main);
  group('Local library', local_library.main);
  group('WebDAV', () => registerDataSyncTransportTests(device: true));
  if (const bool.fromEnvironment('PRIME_SAF_PICKER_TEST')) {
    testWidgets(
      'SAF repeated read/write, listing and migration retain bytes',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Text('Select an empty test directory')),
          ),
        );
        await tester.runAsync(() async {
          await SAFTaskWorker().init();
          final selected = await AndroidDirectory.pickDirectory();
          expect(selected, isNotNull);
          await io.overrideIO(() async {
            final root = Directory(
              '${selected!.path}/prime-test-${DateTime.now().microsecondsSinceEpoch}',
            );
            await root.create();
            final temp = await Directory.systemTemp.createTemp('saf-copy-');
            try {
              final data = List<int>.generate(1024 * 1024 + 31, (i) => i % 251);
              final file = File('${root.path}/page.jpg');
              await file.writeAsBytes(data);
              // Exceeds the old JNI local-reference table capacity; synchronous
              // FFI calls reuse the same Dart thread throughout this loop.
              for (var i = 0; i < 1500; i++) {
                final reopened = File(file.path);
                expect(reopened.lengthSync(), data.length);
                if (i % 100 == 0) expect(reopened.readAsBytesSync(), data);
              }
              await Future.wait(
                List.generate(12, (_) async {
                  expect(await File(file.path).readAsBytes(), data);
                }),
              );
              await io.copyDirectoryIsolate(root, temp);
              expect(await File('${temp.path}/page.jpg').readAsBytes(), data);
            } finally {
              await root.delete(recursive: true);
              await temp.delete(recursive: true);
            }
          });
        });
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
