import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pending_app_links.dart';

void main() {
  test(
    'cold launch waits beyond the old 200ms timeout and opens once',
    () async {
      final opened = <Uri>[];
      final queue = PendingAppLinks(
        (uri) async => opened.add(uri),
        (e, s) => fail('$e'),
      );
      final uri = Uri.parse('https://nhentai.net/g/123/4/');
      queue.add(uri);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(opened, isEmpty);
      queue.setReady(true);
      await Future<void>.delayed(Duration.zero);
      expect(opened, [uri]);
      queue.setReady(true);
      await Future<void>.delayed(Duration.zero);
      expect(opened, [uri]);
    },
  );
  test(
    'locked navigation retains subsequent intents; dispatch errors do not block queue',
    () async {
      final first = Completer<void>();
      final opened = <String>[];
      final errors = <Object>[];
      final queue = PendingAppLinks((uri) async {
        opened.add(uri.path);
        if (uri.path == '/first') await first.future;
        if (uri.path == '/bad') throw StateError('bad');
      }, (e, _) => errors.add(e));
      queue.setReady(true);
      queue.add(Uri.parse('https://example.org/first'));
      queue.add(Uri.parse('https://example.org/bad'));
      queue.add(Uri.parse('https://example.org/last'));
      queue.setReady(false);
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(opened, ['/first']);
      queue.setReady(true);
      await Future<void>.delayed(Duration.zero);
      expect(opened, ['/first', '/bad', '/last']);
      expect(errors, hasLength(1));
    },
  );
  test('gallery page suffix is preserved without stripping gallery IDs', () {
    for (final url in [
      'https://nhentai.net/g/123/7',
      'https://nhentai.net/g/123/7/',
    ]) {
      final target = comicLinkTarget(Uri.parse(url));
      expect(target.uri.toString(), 'https://nhentai.net/g/123/');
      expect(target.page, 7);
    }
    final eh = comicLinkTarget(
      Uri.parse('https://exhentai.org/g/123/abcdef/9/?x=1'),
    );
    expect(eh.uri.toString(), 'https://exhentai.org/g/123/abcdef/?x=1');
    expect(eh.page, 9);
    for (final url in [
      'https://nhentai.net/g/123/',
      'https://e-hentai.org/g/123/456/',
      'https://other.org/comic/123/7',
      'https://nhentai.net/g/123/0',
    ]) {
      final uri = Uri.parse(url);
      expect(comicLinkTarget(uri), (uri: uri, page: null));
    }
  });
}
