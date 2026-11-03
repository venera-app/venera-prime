import 'package:sqlite3/sqlite3.dart';

/// Virtual folders never rename or move downloaded files.
class LocalLibrary {
  final Database db;
  LocalLibrary(this.db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_folders (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, position INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_placement (comic_id TEXT NOT NULL, comic_type INTEGER NOT NULL, folder INTEGER, position INTEGER NOT NULL, PRIMARY KEY(comic_id, comic_type))',
    );
    db.execute(
      'CREATE TRIGGER IF NOT EXISTS local_placement_cleanup AFTER DELETE ON comics BEGIN DELETE FROM local_placement WHERE comic_id = OLD.id AND comic_type = OLD.comic_type; END',
    );
  }

  List<({int id, String name})> get folders => db
      .select('SELECT id, name FROM local_folders ORDER BY position, id')
      .map((r) => (id: r['id'] as int, name: r['name'] as String))
      .toList();

  void createFolder(String name) {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Folder name is empty');
    db.execute(
      'INSERT INTO local_folders(name, position) VALUES (?, (SELECT COALESCE(MAX(position), -1) + 1 FROM local_folders))',
      [name],
    );
  }

  void renameFolder(int id, String name) {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Folder name is empty');
    db.execute('UPDATE local_folders SET name = ? WHERE id = ?', [name, id]);
  }

  void deleteFolder(int id) => _transaction(() {
    db.execute('UPDATE local_placement SET folder = NULL WHERE folder = ?', [
      id,
    ]);
    db.execute('DELETE FROM local_folders WHERE id = ?', [id]);
  });

  void reorderFolders(List<int> ids) => _transaction(() {
    for (var i = 0; i < ids.length; i++) {
      db.execute('UPDATE local_folders SET position = ? WHERE id = ?', [
        i,
        ids[i],
      ]);
    }
  });

  Map<(String, int), ({int? folder, int position})> get placements => {
    for (final r in db.select('SELECT * FROM local_placement'))
      (r['comic_id'] as String, r['comic_type'] as int): (
        folder: r['folder'] as int?,
        position: r['position'] as int,
      ),
  };

  void move(List<(String, int)> comics, int? folder) => _transaction(() {
    if (folder != null &&
        db.select('SELECT id FROM local_folders WHERE id = ?', [
          folder,
        ]).isEmpty) {
      throw ArgumentError('Unknown folder');
    }
    var position =
        db
                .select(
                  'SELECT COALESCE(MAX(position), -1) AS p FROM local_placement',
                )
                .first['p']
            as int;
    for (final comic in comics) {
      db.execute(
        'INSERT INTO local_placement(comic_id, comic_type, folder, position) VALUES (?, ?, ?, ?) ON CONFLICT(comic_id, comic_type) DO UPDATE SET folder = excluded.folder, position = excluded.position',
        [comic.$1, comic.$2, folder, ++position],
      );
    }
  });

  void reorderComics(List<(String, int)> comics) => _transaction(() {
    for (var i = 0; i < comics.length; i++) {
      final comic = comics[i];
      db.execute(
        'INSERT INTO local_placement(comic_id, comic_type, folder, position) VALUES (?, ?, NULL, ?) ON CONFLICT(comic_id, comic_type) DO UPDATE SET position = excluded.position',
        [comic.$1, comic.$2, i],
      );
    }
  });

  void _transaction(void Function() action) {
    db.execute('BEGIN');
    try {
      action();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
