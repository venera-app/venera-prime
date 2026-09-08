import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/archive_security.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart' as native_zip;

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
  if (Platform.environment['PRIME_NATIVE_ZIP_TEST'] == '1') {
    final inputs = await Directory.systemTemp.createTemp('prime-backup-input-');
    final zip = native_zip.ZipFile.open(path);
    try {
      var index = 0;
      for (final entry in files.entries) {
        final input = File('${inputs.path}/${index++}')
          ..writeAsBytesSync(entry.value);
        zip.addFile(entry.key, input.path);
      }
    } finally {
      zip.close();
      await inputs.delete(recursive: true);
    }
    return File(path);
  }
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
      final cookies = SingleInstanceCookieJar('${directory.path}/cookie.db');
      final uri = Uri.parse('https://example.test/login');
      cookies.saveFromResponse(uri, [Cookie('session', 'fixture-session')]);
      final cookieBytes = File(cookies.path).readAsBytesSync();
      cookies.deleteAll();

      final databaseBytes = File(
        '${directory.path}/read_later.db',
      ).readAsBytesSync();
      final completeBackup = await _archive(
        '${directory.path}/complete.venera',
        {
          'appdata.json': utf8.encode(
            jsonEncode({
              'settings': {
                'token': 'fixture-token',
                'webdav': [
                  'https://backup.example.test',
                  'fixture-user',
                  'fixture-password',
                ],
              },
              'searchHistory': [],
            }),
          ),
          'history.db': _emptyDatabase('${directory.path}/history.db'),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/local_favorite.db',
          ),
          'read_later.db': databaseBytes,
          'cookie.db': cookieBytes,
        },
      );
      manager.clear();
      await importAppData(completeBackup);
      expect(manager.getAll().single.id, 'backup-id');
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
      expect(appdata.settings['token'], 'fixture-token');
      expect(appdata.settings['webdav'][2], 'fixture-password');

      final corruptCookiesBackup = await _archive(
        '${directory.path}/bad-cookie.venera',
        {
          'history.db': _emptyDatabase(
            '${directory.path}/bad-cookie-history.db',
          ),
          'local_favorite.db': _emptyDatabase(
            '${directory.path}/bad-cookie-favorites.db',
          ),
          'appdata.json': utf8.encode(
            jsonEncode({'settings': {}, 'searchHistory': []}),
          ),
          'cookie.db': utf8.encode('not a database'),
        },
      );
      await expectLater(
        importAppData(corruptCookiesBackup),
        throwsA(isA<SqliteException>()),
      );
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
      expect(manager.getAll().single.id, 'backup-id');

      if (Platform.environment['PRIME_NATIVE_ZIP_TEST'] == '1') {
        final sourceDir = Directory('${directory.path}/comic_source')
          ..createSync();
        final sourceData = File('${sourceDir.path}/fixture.data');
        sourceData.writeAsStringSync(
          jsonEncode({
            'account': ['fixture-user', 'fixture-password'],
            'nested': {
              'Authorization': 'fixture-auth',
              'refresh_token': 'fixture-refresh',
            },
          }),
        );
        for (final sync in [false, true]) {
          final exported = await exportAppData(sync);
          final extracted = Directory('${cache.path}/export-$sync');
          await ArchiveSecurity.extract(exported, extracted);
          expect(
            File(
              '${extracted.path}/comic_source/fixture.data',
            ).readAsStringSync(),
            sourceData.readAsStringSync(),
          );
          final settings = jsonDecode(
            File('${extracted.path}/appdata.json').readAsStringSync(),
          )['settings'];
          expect(settings['token'], 'fixture-token');
          expect(settings.containsKey('webdav'), !sync);
          final exportedCookies = CookieJarSql('${extracted.path}/cookie.db');
          expect(
            exportedCookies.loadForRequest(uri).single.value,
            'fixture-session',
          );
          exportedCookies.dispose();
          final expectedSourceData = sourceData.readAsStringSync();
          sourceData.writeAsStringSync('{}');
          cookies.deleteAll();
          await importAppData(exported);
          expect(sourceData.readAsStringSync(), expectedSourceData);
          expect(cookies.loadForRequest(uri).single.value, 'fixture-session');
          await exported.delete();
        }
        await sourceDir.delete(recursive: true);
        JsEngine().dispose();
      }

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
      expect(cookies.loadForRequest(uri).single.value, 'fixture-session');

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
      cookies.dispose();
      SingleInstanceCookieJar.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    },
  );
}
