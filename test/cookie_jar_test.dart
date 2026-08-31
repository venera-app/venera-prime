import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cookie_jar.dart';

void main() {
  test('enforces host-only, domain, secure, and path boundaries', () async {
    final directory = await Directory.systemTemp.createTemp('venera-cookie-');
    final jar = CookieJarSql('${directory.path}/cookies.db');
    final hostCookie = Cookie('host', '1')..path = '/foo';
    final domainCookie = Cookie('domain', '1')
      ..domain = 'example.com'
      ..path = '/';
    final secureCookie = Cookie('secure', '1')
      ..secure = true
      ..path = '/';
    jar.saveFromResponse(Uri.parse('https://sub.example.com/foo'), [
      hostCookie,
      domainCookie,
      secureCookie,
    ]);

    final httpsFoo = jar.loadForRequest(
      Uri.parse('https://sub.example.com/foo'),
    );
    expect(
      httpsFoo.map((cookie) => cookie.name),
      containsAll(['host', 'domain', 'secure']),
    );
    expect(
      jar
          .loadForRequest(Uri.parse('http://sub.example.com/foo'))
          .map((cookie) => cookie.name),
      isNot(contains('secure')),
    );
    expect(
      jar
          .loadForRequest(Uri.parse('https://sub.example.com/foobar'))
          .map((cookie) => cookie.name),
      isNot(contains('host')),
    );
    expect(
      jar
          .loadForRequest(Uri.parse('https://other.example.com/foo'))
          .map((cookie) => cookie.name),
      isNot(contains('host')),
    );
    expect(
      jar
          .loadForRequest(Uri.parse('https://other.example.com/foo'))
          .map((cookie) => cookie.name),
      contains('domain'),
    );
    jar.dispose();
    await directory.delete(recursive: true);
  });
}
