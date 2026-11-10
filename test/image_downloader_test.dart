import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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
  test('refresh ignores a late response from the invalidated request', () async {
    final root = await Directory.systemTemp.createTemp('prime-image-refresh-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    CacheManager.instance = null;
    appdata.settings['proxy'] = 'direct';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstRequest = Completer<HttpRequest>();
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
    );
    final fresh = [...image, 42];
    var requests = 0;
    final subscription = server.listen((request) async {
      if (++requests == 1) {
        firstRequest.complete(request);
      } else {
        request.response.add(fresh);
        await request.response.close();
      }
    });
    final url = 'http://127.0.0.1:${server.port}/page.png';
    try {
      final old = ImageDownloader.loadComicImage(url, null, 'c', 'e').toList();
      final pending = await firstRequest.future.timeout(
        const Duration(seconds: 10),
      );
      await ImageDownloader.invalidateComicImage(url, null, 'c', 'e');
      final events = await ImageDownloader.loadComicImage(
        url,
        null,
        'c',
        'e',
      ).toList();
      expect(events.last.imageBytes, fresh);
      pending.response.add(image);
      await pending.response.close();
      await old;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await CacheManager().readCache('$url@null@c@e'), fresh);
      expect(requests, 2);
    } finally {
      ImageDownloader.cancelAllLoadingImages();
      await subscription.cancel();
      await server.close(force: true);
      CacheManager.instance = null;
      await root.delete(recursive: true);
    }
  });
}
