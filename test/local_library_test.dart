import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/local_library.dart';

void main() {
  late Database db;
  late LocalLibrary library;
  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(
      'CREATE TABLE comics (id TEXT, comic_type INTEGER, PRIMARY KEY(id, comic_type))',
    );
    library = LocalLibrary(db);
  });
  tearDown(() => db.dispose());

  test(
    'folders and ordering persist across model recreation without conflating sources',
    () {
      library.createFolder('A');
      library.createFolder('B');
      final a = library.folders.first.id;
      final b = library.folders.last.id;
      library.move([('same', 1)], a);
      library.move([('same', 2)], b);
      library.reorderComics([('same', 2), ('same', 1)]);
      library.reorderFolders([b, a]);
      library = LocalLibrary(db);
      expect(library.folders.map((f) => f.name), ['B', 'A']);
      expect(library.placements[('same', 1)], (folder: a, position: 1));
      expect(library.placements[('same', 2)], (folder: b, position: 0));
      library.renameFolder(a, 'Renamed');
      expect(library.folders.last.name, 'Renamed');
    },
  );

  test('removing category keeps comics and moves them to uncategorized', () {
    db.execute("INSERT INTO comics VALUES ('one', 1), ('two', 2)");
    library.createFolder('A');
    library.move([('one', 1), ('two', 2)], library.folders.single.id);
    library.deleteFolder(library.folders.single.id);
    expect(db.select('SELECT * FROM comics'), hasLength(2));
    expect(library.placements.values.every((v) => v.folder == null), isTrue);
    db.execute("DELETE FROM comics WHERE id = 'one'");
    expect(library.placements.containsKey(('one', 1)), isFalse);
    expect(library.placements.containsKey(('two', 2)), isTrue);
  });

  test('invalid folder and duplicate names leave existing metadata intact', () {
    library.createFolder('A');
    expect(() => library.createFolder(' A '), throwsA(isA<SqliteException>()));
    expect(() => library.createFolder(' '), throwsArgumentError);
    expect(() => library.move([('one', 1)], 987), throwsArgumentError);
    expect(library.placements, isEmpty);
    library.move([('one', 1)], library.folders.single.id);
    expect(library.placements, hasLength(1));
  });
}
