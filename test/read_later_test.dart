import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/read_later.dart';

void main() {
  test('read later keeps source identity and rejects duplicates', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-read-later-',
    );
    App.dataPath = directory.path;
    final manager = ReadLaterManager();
    manager.close();
    await manager.init();
    manager.clear();

    const first = Comic(
      'First',
      'cover-1',
      'same-id',
      'author',
      ['tag'],
      '',
      'source-a',
      null,
      null,
    );
    const second = Comic(
      'Second',
      'cover-2',
      'same-id',
      'author',
      ['tag'],
      '',
      'source-b',
      null,
      null,
    );
    expect(manager.add(first), isTrue);
    expect(manager.add(first), isFalse);
    expect(manager.add(second), isTrue);
    expect(manager.getAll(), hasLength(2));

    manager.removeMany(manager.getAll());
    expect(manager.getAll(), isEmpty);
    manager.close();
    await directory.delete(recursive: true);
  });

  test('migrates an older table and recovers a corrupt database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-read-later-migration-',
    );
    App.dataPath = directory.path;
    final path = '${directory.path}/read_later.db';
    final oldDb = sqlite3.open(path);
    oldDb.execute('''
      CREATE TABLE read_later (
        id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        source_key TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    oldDb.execute(
      '''INSERT INTO read_later
         (id, comic_type, source_key, title, subtitle, tags, cover, added_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?);''',
      ['legacy', ComicType.local.value, 'local', 'Legacy', '', '[]', '', 1],
    );
    oldDb.dispose();

    final manager = ReadLaterManager();
    manager.close();
    await manager.init();
    expect(manager.getAll().single.description, isEmpty);
    expect(File(path).readAsBytesSync(), isNotEmpty);

    manager.close();
    await File(path).writeAsString('not a sqlite database');
    await manager.init();
    expect(manager.getAll(), isEmpty);
    expect(
      directory.listSync().whereType<File>().any(
        (file) => file.path.contains('.corrupt.'),
      ),
      isTrue,
    );
    manager.close();
    await directory.delete(recursive: true);
  });
}
