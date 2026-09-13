import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache hit returns without attempting another network request', () async {
    final root = await Directory.systemTemp.createTemp('prime-image-download-');
    try {
      App.dataPath = root.path;
      App.cachePath = Directory('${root.path}/cache').path;
      CacheManager.instance = null;
      const url = 'http://127.0.0.1:1/must-not-be-requested.png';
      const cacheKey = '$url@null@comic@chapter';
      final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      );
      await CacheManager().writeCache(cacheKey, imageBytes);

      final events = await ImageDownloader.loadComicImageUnwrapped(
        url,
        null,
        'comic',
        'chapter',
      ).toList();

      expect(events, hasLength(1));
      expect(events.single.imageBytes, imageBytes);
    } finally {
      CacheManager.instance = null;
      await root.delete(recursive: true);
    }
  });
}
