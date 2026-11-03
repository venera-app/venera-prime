import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';

class _LockedFile implements File {
  _LockedFile(this.actual);
  final File actual;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw FileSystemException(
        'File locked by another process',
        path,
        const OSError('sharing violation', 32),
      );
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _LockedDirectory implements Directory {
  _LockedDirectory(this.actual);
  final Directory actual;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => actual
      .listSync(recursive: recursive, followLinks: followLinks)
      .map((e) => e is File ? _LockedFile(e) : e)
      .toList();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final class _LockedOverrides extends IOOverrides {
  _LockedOverrides(this.locked);
  final String locked;
  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return path == locked ? _LockedDirectory(directory) : directory;
  }
}

void main() {
  test(
    'committed storage migration survives Windows-style source cleanup failure',
    () async {
      final root = await Directory.systemTemp.createTemp('storage-move-');
      final old = Directory('${root.path}/old')..createSync();
      final target = Directory('${root.path}/new')..createSync();
      final bytes = List<int>.generate(200000, (i) => i % 251);
      File('${old.path}/page.jpg').writeAsBytesSync(bytes);
      App.dataPath = root.path;
      File('${root.path}/local_path').writeAsStringSync(old.path);
      final manager = LocalManager();
      manager.close();
      try {
        await manager.init();
        await IOOverrides.runWithIOOverrides(() async {
          expect(await manager.setNewPath(target.path), isNull);
        }, _LockedOverrides(old.path));
        expect(manager.path, target.path);
        expect(File('${root.path}/local_path').readAsStringSync(), target.path);
        expect(File('${target.path}/page.jpg').readAsBytesSync(), bytes);
        expect(File('${old.path}/page.jpg').existsSync(), isTrue);
        manager.close();
        await manager.init();
        expect(manager.path, target.path);
      } finally {
        manager.close();
        await root.delete(recursive: true);
      }
    },
  );
}
