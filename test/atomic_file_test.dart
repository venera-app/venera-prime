import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/atomic_file.dart';

void main() {
  test('restores the original source when replacement fails', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-atomic-file-',
    );
    final target = File('${directory.path}/source.js')
      ..writeAsStringSync('old');
    final temporary = Directory('${directory.path}/source.js.tmp')
      ..createSync();
    final backup = File('${directory.path}/source.js.bak');
    var renameCount = 0;

    await expectLater(
      atomicReplaceWithBackup(
        target: target,
        temporary: File('${directory.path}/source.js.tmp-file')
          ..writeAsStringSync('new'),
        backup: backup,
        rename: (source, destination) async {
          renameCount++;
          if (renameCount == 2) {
            throw const FileSystemException('injected rename failure');
          }
          return File(source).rename(destination);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(target.readAsStringSync(), 'old');
    expect(backup.existsSync(), isFalse);

    await temporary.delete(recursive: true);
    await directory.delete(recursive: true);
  });
}
