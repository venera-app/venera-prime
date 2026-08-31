import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/archive_security.dart';

Future<File> _zip(
  String path,
  Iterable<ArchiveFile> files, {
  int level = 1,
}) async {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  final output = File(path);
  output.writeAsBytesSync(ZipEncoder().encodeBytes(archive, level: level));
  return output;
}

void main() {
  test('rejects unsafe ZIP entry names', () async {
    final directory = await Directory.systemTemp.createTemp('venera-archive-');
    for (final name in ['../escape.txt', '/absolute.txt', r'C:\absolute.txt']) {
      expect(
        () => ArchiveSecurity.safeTarget('${directory.path}/output', name),
        throwsA(isA<FormatException>()),
      );
    }
    await directory.delete(recursive: true);
  });

  test('rejects an unsafe compression ratio before extraction', () async {
    final directory = await Directory.systemTemp.createTemp('venera-archive-');
    final archive = await _zip('${directory.path}/bomb.zip', [
      ArchiveFile.bytes('large.bin', List<int>.filled(32 * 1024 * 1024, 0)),
    ], level: 9);
    await expectLater(
      ArchiveSecurity.extract(archive, Directory('${directory.path}/out')),
      throwsA(isA<FormatException>()),
    );
    await directory.delete(recursive: true);
  });
}
