import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';

void main() {
  test('Windows protocol assignments work with one or several protocols', () {
    expect(
      normalizeSystemProxy('http=127.0.0.1:7897'),
      'http://127.0.0.1:7897',
    );
    expect(
      normalizeSystemProxy('http=first:80; https=second:443'),
      'http://second:443',
    );
    expect(
      normalizeSystemProxy(' socks=ignored:1080; HTTP = first:80 '),
      'http://first',
    );
    expect(
      normalizeSystemProxy('https=broken/path;http=first:8080'),
      'http://first:8080',
    );
    expect(normalizeSystemProxy('socks=ignored:1080'), isNull);
  });
  test('normalizes manual host and port for both HTTP adapters', () async {
    final previous = appdata.settings['proxy'];
    try {
      appdata.settings['proxy'] = '127.0.0.1:8080';
      expect(await getProxy(), 'http://127.0.0.1:8080');

      appdata.settings['proxy'] = 'user:secret@proxy.example:3128';
      expect(await getProxy(), 'http://user:secret@proxy.example:3128');
    } finally {
      appdata.settings['proxy'] = previous;
    }
  });

  test('ignores invalid manual proxy settings', () async {
    final previous = appdata.settings['proxy'];
    try {
      appdata.settings['proxy'] = 'socks5://proxy.example:1080';
      expect(await getProxy(), isNull);

      appdata.settings['proxy'] = 'proxy.example:70000';
      expect(await getProxy(), isNull);
    } finally {
      appdata.settings['proxy'] = previous;
    }
  });
  for (final authenticated in [false, true]) {
    test(
      'Dart HTTP requests reach the configured proxy (auth=$authenticated)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        final subscription = server.listen((request) async {
          requests++;
          if (authenticated &&
              request.headers.value('proxy-authorization') !=
                  'Basic ${base64Encode(utf8.encode('user:p:a ss'))}') {
            request.response.statusCode =
                HttpStatus.proxyAuthenticationRequired;
            request.response.headers.set(
              'proxy-authenticate',
              'Basic realm="test"',
            );
          } else {
            request.response.write('proxy response');
          }
          await request.response.close();
        });
        final credentials = authenticated ? 'user:p%3Aa%20ss@' : '';
        final client = createProxyHttpClient(
          'http://${credentials}127.0.0.1:${server.port}',
        );
        try {
          final request = await client.getUrl(
            Uri.parse('http://source.invalid/comic'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
          expect(
            await response.transform(utf8.decoder).join(),
            'proxy response',
          );
          expect(response.statusCode, HttpStatus.ok);
          expect(requests, authenticated ? 2 : 1);
        } finally {
          client.close(force: true);
          await server.close(force: true);
          await subscription.cancel();
        }
      },
    );
  }
}
