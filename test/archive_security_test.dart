import 'dart:io';
import 'dart:typed_data';

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
  test(
    'extracts a sparse ZIP larger than 512 MiB without whole-file reads',
    () async {
      final root = await Directory.systemTemp.createTemp('large-stream-zip-');
      try {
        final archive = Archive()
          ..addFile(ArchiveFile.bytes('page.txt', [1, 2, 3]));
        final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
        final view = ByteData.sublistView(bytes);
        final end = bytes.length - 22;
        final central = view.getUint32(end + 16, Endian.little);
        const prefix = 513 * 1024 * 1024;
        view.setUint32(central + 42, prefix, Endian.little);
        view.setUint32(end + 16, central + prefix, Endian.little);
        final input = File('${root.path}/large.zip');
        final handle = await input.open(mode: FileMode.write);
        await handle.setPosition(prefix);
        await handle.writeFrom(bytes);
        await handle.close();
        final output = Directory('${root.path}/out');
        await ArchiveSecurity.extractZip(input, output);
        expect(await File('${output.path}/page.txt').readAsBytes(), [1, 2, 3]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

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
