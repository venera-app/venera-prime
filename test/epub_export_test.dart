import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/epub.dart';
import 'package:xml/xml.dart';

void main() {
  test(
    'concurrent EPUB exports retain every image and resolve manifest paths',
    () async {
      final root = await Directory.systemTemp.createTemp('epub-export-');
      try {
        final bytes = Uint8List.fromList(
          List.generate(512 * 1024, (i) => i % 251),
        );
        final image = File('${root.path}/image.jpg')..writeAsBytesSync(bytes);
        final data = EpubData(
          title: 'A & B',
          author: 'C < D',
          cover: image,
          chapters: {
            'Chapter 1 & 2': [image, image],
          },
        );
        final outputs = await Future.wait([
          for (var i = 0; i < 2; i++)
            createEpubComic(data, root.path, '${root.path}/book$i.epub'),
        ]);
        for (final output in outputs) {
          final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
          for (final name in ['cover.jpg', 'img0.jpg', 'img1.jpg']) {
            expect(archive.find('OEBPS/images/$name')!.readBytes(), bytes);
          }
          final document = XmlDocument.parse(
            String.fromCharCodes(archive.find('content.opf')!.readBytes()!),
          );
          for (final item in document.findAllElements('item')) {
            expect(archive.find(item.getAttribute('href')!), isNotNull);
          }
          expect(
            document.findAllElements('dc:title').single.innerText,
            'A & B',
          );
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
