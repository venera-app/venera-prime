import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'manual binding persists origin without replacing scripts and invalidates updates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'prime-binding-test-',
      );
      App.dataPath = directory.path;
      appdata.settings['webdav'] = [];
      appdata.settings['comicSourceLibraries'] = [
        ComicSourceLibrary(
          id: 'a',
          name: 'A',
          url: 'https://example.test/a.json',
        ).toJson(),
        ComicSourceLibrary(
          id: 'disabled',
          name: 'Disabled',
          url: 'https://example.test/b.json',
          enabled: false,
        ).toJson(),
      ];
      appdata.settings['comicSourceProvenance'] = <String, dynamic>{};
      final script = File('${directory.path}/local.js')
        ..writeAsStringSync('original script');
      try {
        expect(ComicSourceLibraryManager.isUnbound('fixture'), isTrue);
        await expectLater(
          ComicSourceLibraryManager.bindUnassignedSource(
            sourceKey: 'fixture',
            libraryId: 'disabled',
            sourceFileName: 'remote.js',
          ),
          throwsStateError,
        );
        await expectLater(
          ComicSourceLibraryManager.bindUnassignedSource(
            sourceKey: 'fixture',
            libraryId: 'missing',
            sourceFileName: 'remote.js',
          ),
          throwsStateError,
        );
        ComicSourceManager().setUpdateUrl(
          'fixture',
          'https://old.test/source.js',
        );
        await ComicSourceLibraryManager.bindUnassignedSource(
          sourceKey: 'fixture',
          libraryId: 'a',
          sourceFileName: 'remote.js',
        );
        final provenance = ComicSourceLibraryManager.provenanceFor('fixture')!;
        expect(provenance.originId, 'a');
        expect(provenance.updateLibraryId, 'a');
        expect(provenance.sourceFileName, 'remote.js');
        expect(ComicSourceLibraryManager.isUnbound('fixture'), isFalse);
        expect(ComicSourceManager().updateUrlFor('fixture'), isNull);
        expect(script.readAsStringSync(), 'original script');
        expect(
          File('${directory.path}/appdata.json').readAsStringSync(),
          contains('remote.js'),
        );
        await expectLater(
          ComicSourceLibraryManager.bindUnassignedSource(
            sourceKey: 'fixture',
            libraryId: 'a',
            sourceFileName: 'other.js',
          ),
          throwsStateError,
        );
        appdata.settings['comicSourceLibraries'] = [];
        expect(ComicSourceLibraryManager.isUnbound('fixture'), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'migration runs once and deleted legacy catalogs stay deleted',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'prime-catalog-test-',
      );
      App.dataPath = directory.path;
      appdata.settings['comicSourceLibrariesMigrated'] = false;
      appdata.settings['comicSourceLibraries'] = [];
      appdata.settings['comicSourceListUrl'] = 'https://example.com/index.json';
      ComicSourceLibraryManager.migrateLegacy();
      final library = ComicSourceLibraryManager.all().single;
      ComicSourceLibraryManager.remove(library.id);
      ComicSourceLibraryManager.migrateLegacy();
      expect(ComicSourceLibraryManager.all(), isEmpty);
      await appdata.saveData(false);
      await directory.delete(recursive: true);
    },
  );

  test(
    'catalog mutations persist state and invalidate update candidates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'prime-catalog-test-',
      );
      App.dataPath = directory.path;
      appdata.settings['comicSourceLibraries'] = [];
      final a = ComicSourceLibraryManager.add(
        'A',
        'https://example.com/a.json',
      );
      final b = ComicSourceLibraryManager.add(
        'B',
        'https://example.com/b.json',
      );
      ComicSourceManager().setUpdateUrl(
        'test-key',
        'https://example.com/source.js',
      );
      ComicSourceLibraryManager.setEnabled(a.id, false);
      expect(ComicSourceLibraryManager.find(a.id)!.enabled, isFalse);
      expect(ComicSourceManager().updateUrlFor('test-key'), isNull);
      ComicSourceLibraryManager.edit(a.id, name: 'Renamed');
      expect(ComicSourceLibraryManager.find(a.id)!.name, 'Renamed');
      expect(
        () => ComicSourceLibraryManager.edit(a.id, url: b.url),
        throwsArgumentError,
      );
      ComicSourceLibraryManager.reorder(1, 0);
      expect(ComicSourceLibraryManager.all().first.id, b.id);
      await appdata.saveData(false);
      expect(
        await File('${directory.path}/appdata.json').readAsString(),
        contains('Renamed'),
      );
      await directory.delete(recursive: true);
    },
  );
  test('rejects non HTTP URLs and embedded credentials', () {
    for (final url in [
      'file:///tmp/a.js',
      'ftp://example.com/a',
      'https://user:pass@example.com/a',
    ]) {
      expect(isHttpSourceUrl(url), isFalse);
      expect(
        resolveSourceDownloadUrl(
          url: url,
          listUrl: 'https://example.com/index.json',
        ),
        isNull,
      );
    }
    expect(isHttpSourceUrl('http://127.0.0.1:8080/index.json'), isTrue);
  });

  test('malformed optional backup fields do not crash deserialization', () {
    expect(
      ComicSourceLibrary.fromJson({
        'priority': 'bad',
        'lastChecked': [],
      }).priority,
      0,
    );
    expect(
      SourceProvenance.fromJson({'libraryIds': 'bad'}).libraryIds,
      isEmpty,
    );
    expect(
      SourceProvenance.fromJson({
        'libraryIds': ['valid', 42],
      }).libraryIds,
      ['valid'],
    );
  });
  test('normalizes catalog URLs and derives stable IDs', () {
    expect(
      stableLibraryId('HTTPS://Example.com/catalog/index.json/'),
      stableLibraryId('https://example.com/catalog/index.json'),
    );
    expect(
      stableLibraryId('https://example.com/a'),
      isNot(stableLibraryId('https://example.com/b')),
    );
  });

  test('allocates a deterministic fallback when the short ID is occupied', () {
    const url = 'https://example.com/index.json';
    final shortId = stableLibraryId(url);
    final allocated = allocateLibraryId(url, [shortId]);
    expect(allocated, isNot(shortId));
    expect(allocated, allocateLibraryId(url, [shortId]));
  });

  test('serializes libraries and provenance without losing state', () {
    final library = ComicSourceLibrary(
      id: 'lib-a',
      name: 'Primary',
      url: 'https://example.com/index.json',
      enabled: false,
      priority: 2,
      lastChecked: 42,
    );
    final restored = ComicSourceLibrary.fromJson(library.toJson());
    expect(restored.toJson(), library.toJson());

    final provenance = SourceProvenance(
      libraryIds: ['lib-a', 'lib-b'],
      originId: 'lib-a',
      updateLibraryId: 'lib-a',
      sourceFileName: 'source.js',
    );
    expect(
      SourceProvenance.fromJson(provenance.toJson()).toJson(),
      provenance.toJson(),
    );
  });

  test('finds a catalog by normalized URL', () {
    final library = ComicSourceLibrary(
      id: 'lib-a',
      name: 'Catalog',
      url: 'https://EXAMPLE.com/index.json/',
    );
    expect(
      findLibraryByUrl([library], 'https://example.com/index.json'),
      same(library),
    );
  });

  test('resolves absolute and relative source download URLs', () {
    const catalog = 'https://example.com/catalog/index.json';
    expect(
      resolveSourceDownloadUrl(
        url: 'https://cdn.example.com/source.js',
        listUrl: catalog,
      ),
      'https://cdn.example.com/source.js',
    );
    expect(
      resolveSourceDownloadUrl(url: 'scripts/source.js', listUrl: catalog),
      'https://example.com/catalog/scripts/source.js',
    );
    expect(
      resolveSourceDownloadUrl(fileName: 'source.js', listUrl: catalog),
      'https://example.com/catalog/source.js',
    );
  });
}
