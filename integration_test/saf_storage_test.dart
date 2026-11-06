import 'package:archive/archive.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/epub.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'SAF listed files survive reopen, export and worker exit',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Select an empty SAF test folder')),
        ),
      );
      await SAFTaskWorker().init();
      final root = await AndroidDirectory.pickDirectory();
      expect(root, isNotNull);
      final cache = (await getTemporaryDirectory()).path;
      final bytes = List<int>.generate(8192, (i) => i % 251);
      await overrideIO(() async {
        final dir = Directory(
          '${root!.path}/prime-regression-${DateTime.now().microsecondsSinceEpoch}',
        )..createSync();
        final file = File('${dir.path}/page.jpg')..writeAsBytesSync(bytes);
        expect(file.readAsBytesSync(), bytes);
        final listed = Directory(dir.path).listSync().whereType<File>().single;
        // A fresh listing is also what the library uses after an application restart.
        expect(listed.lengthSync(), bytes.length);
        expect(listed.readAsBytesSync(), bytes);
        final nested = Directory('${dir.path}/nested')..createSync();
        File('${nested.path}/page.jpg').writeAsBytesSync(bytes);
        expect(await dir.size, bytes.length * 2);
        final recursiveFiles = await dir
            .list(recursive: true)
            .where((entity) => entity is File)
            .toList();
        expect(recursiveFiles, hasLength(2));
        final path = listed.path;
        final dataDir = await Directory(cache).createTemp('saf-library-');
        App.dataPath = dataDir.path;
        App.cachePath = cache;
        File('${dataDir.path}/local_path').writeAsStringSync(root.path);
        final local = LocalManager();
        await local.init();
        await local.add(
          LocalComic(
            id: 'saf-regression',
            title: 'SAF regression',
            subtitle: 'test',
            tags: [],
            directory: dir.path,
            chapters: null,
            cover: 'page.jpg',
            comicType: ComicType.local,
            downloadedChapters: [],
            createdAt: DateTime.now(),
          ),
        );
        // Reload the persisted library, as on a subsequent launch.
        local.close();
        await local.init();
        final comic = local.find('saf-regression', ComicType.local)!;
        final output = await createEpubWithLocalComic(
          comic,
          '$cache/saf-regression.epub',
        );
        final archive = ZipDecoder().decodeBytes(output.readAsBytesSync());
        expect(archive.find('OEBPS/images/cover.jpg')!.readBytes(), bytes);
        expect(archive.find('OEBPS/images/img0.jpg')!.readBytes(), bytes);
        local.close();
        await dataDir.delete(recursive: true);
        // Dart workers retire after being idle; attached JNI threads must detach.
        await Future<void>.delayed(const Duration(seconds: 75));
        expect(File(path).readAsBytesSync(), bytes);
        dir.deleteSync(recursive: true);
      });
    },
    timeout: const Timeout(Duration(minutes: 8)),
    // Requires granting a disposable folder in Android's document picker.
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('PRIME_SAF_DEVICE_TEST'),
  );
}
