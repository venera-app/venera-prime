import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/data.dart';

Comic _comic() => const Comic(
  'Backup comic',
  'cover',
  'backup-id',
  'author',
  ['backup'],
  '',
  'backup-source',
  null,
  null,
);

Future<File> _archive(String path, Map<String, List<int>> files) async {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(
      ArchiveFile.bytes(entry.key, Uint8List.fromList(entry.value)),
    );
  }
  return File(path)..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

List<int> _emptyDatabase(String path) {
  final db = sqlite3.open(path);
  db.dispose();
  return File(path).readAsBytesSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'imports read later entries and preserves them for old backups',
    () async {
      final directory = await Directory.systemTemp.createTemp('venera-backup-');
      final cache = Directory('${directory.path}/cache')..createSync();
      App.dataPath = directory.path;
      App.cachePath = cache.path;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async {
            return directory.path;
          });

      final manager = ReadLaterManager();
      manager.close();
      await manager.init();
      manager.clear();
      expect(manager.add(_comic()), isTrue);

      final databaseBytes = File(
        '${directory.path}/read_later.db',
      ).readAsBytesSync();
      final completeBackup = await _archive(
        '${directory.path}/complete.venera',
        {
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'history.db': _emptyDatabase('${directory.path}/history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/local_favorite.db',
          ),
          'read_later.db': databaseBytes,
        },
      );
      manager.clear();
      await importAppData(completeBackup);
      expect(manager.getAll().single.id, 'backup-id');

      final legacyBackup = await _archive('${directory.path}/legacy.venera', {
        'history.db': _emptyDatabase('${directory.path}/legacy-history.db'),
        'local_favorite.db': _emptyDatabase(
          '${directory.path}/legacy-favorite.db',
        ),
        'appdata.json': utf8.encode(
          jsonEncode({'settings': {}, 'searchHistory': []}),
        ),
      });
      await importAppData(legacyBackup);
      expect(manager.getAll().single.id, 'backup-id');

      final invalidManifestBackup = await _archive(
        '${directory.path}/invalid-manifest.venera',
        {
          'history.db': _emptyDatabase('${directory.path}/invalid-history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/invalid-favorite.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'manifest.json': utf8.encode(
            jsonEncode({'format': 99, 'files': <String>[]}),
          ),
        },
      );
      await expectLater(
        importAppData(invalidManifestBackup),
        throwsA(isA<FormatException>()),
      );

      manager.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    },
  );
}
