import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/archive_security.dart';
import 'package:zip_flutter/zip_flutter.dart';

void main() {
  test(
    'extracts an archive produced by the Venera 1.6 ZIP writer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'prime-legacy-zip-',
      );
      try {
        final input = File('${directory.path}/data.json')
          ..writeAsStringSync('{"settings":{},"searchHistory":[]}');
        final file = File('${directory.path}/legacy.venera');
        final zip = ZipFile.open(file.path);
        zip.addFile('appdata.json', input.path);
        zip.close();
        final output = Directory('${directory.path}/out');
        await ArchiveSecurity.extract(file, output);
        expect(
          File('${output.path}/appdata.json').readAsStringSync(),
          input.readAsStringSync(),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1'
        ? 'Set PRIME_NATIVE_ZIP_TEST=1 with the built zip_flutter library on the library search path.'
        : false,
  );
}
