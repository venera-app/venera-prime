import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/restore_files.dart';

void main() {
  for (var failAt = 1; failAt <= 6; failAt++) {
    test(
      'rollback preserves every original after rename failure $failAt',
      () async {
        final root = await Directory.systemTemp.createTemp('prime-restore-');
        try {
          final live = Directory('${root.path}/live')..createSync();
          final staging = Directory('${root.path}/staging')..createSync();
          final backup = Directory('${root.path}/backup');
          const names = ['history.db', 'appdata.json', 'comic_source'];
          for (final name in names) {
            File('${live.path}/$name').writeAsStringSync('old-$name');
            File('${staging.path}/$name').writeAsStringSync('new-$name');
          }
          var calls = 0;
          final transaction = RestoreFiles(
            staging: staging,
            live: live,
            backup: backup,
            names: names,
            rename: (from, to) async {
              if (++calls == failAt) {
                throw const FileSystemException('injected');
              }
              await File(from).rename(to);
            },
          );
          await expectLater(
            transaction.apply(),
            throwsA(isA<FileSystemException>()),
          );
          await transaction.rollback();
          for (final name in names) {
            expect(File('${live.path}/$name').readAsStringSync(), 'old-$name');
          }
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }
}
