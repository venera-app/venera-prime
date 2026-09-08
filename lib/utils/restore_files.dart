import 'dart:io';

import 'package:path/path.dart' as p;

/// Tracks exactly which paths moved so a partial restore cannot delete
/// untouched live files. Callers close open databases before apply/rollback.
class RestoreFiles {
  RestoreFiles({
    required this.staging,
    required this.live,
    required this.backup,
    required this.names,
    this.rename,
  });

  final Directory staging;
  final Directory live;
  final Directory backup;
  final List<String> names;
  final Future<void> Function(String from, String to)? rename;
  final _saved = <String>[];
  final _installed = <String>[];

  Future<void> _move(String from, String to) async {
    if (rename != null) return rename!(from, to);
    if (FileSystemEntity.typeSync(from, followLinks: false) ==
        FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  Future<void> apply() async {
    for (final name in names) {
      if (p.basename(name) != name || name == '.' || name == '..') {
        throw ArgumentError('Restore targets must be simple file names');
      }
    }
    await backup.create(recursive: true);
    for (final name in names) {
      final current = p.join(live.path, name);
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _move(current, p.join(backup.path, name));
        _saved.add(name);
      }
    }
    for (final name in names) {
      await _move(p.join(staging.path, name), p.join(live.path, name));
      _installed.add(name);
    }
  }

  Future<void> rollback() async {
    Object? failure;
    for (final name in _installed.reversed) {
      final current = p.join(live.path, name);
      try {
        final type = FileSystemEntity.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(current).delete(recursive: true);
        } else if (type == FileSystemEntityType.link) {
          await Link(current).delete();
        } else if (type != FileSystemEntityType.notFound) {
          await File(current).delete();
        }
      } catch (e) {
        failure ??= e;
      }
    }
    for (final name in _saved.reversed) {
      try {
        final target = p.join(live.path, name);
        if (FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('Restore rollback target is occupied: $name');
        }
        await _move(p.join(backup.path, name), target);
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw failure;
  }
}
