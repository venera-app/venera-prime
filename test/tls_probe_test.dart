import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart';

void main() {
  test(
    'anonymous RHTTP HEAD TLS probe',
    () async {
      await Rhttp.init();
      final response = await Rhttp.head(
        Platform.environment['PRIME_TLS_URL']!,
        settings: const ClientSettings(
          throwOnStatusCode: false,
          proxySettings: ProxySettings.noProxy(),
          tlsSettings: TlsSettings(sni: true, verifyCertificates: true),
          timeoutSettings: TimeoutSettings(timeout: Duration(seconds: 20)),
        ),
      );
      // Do not print headers, cookies, response body or user credentials.
      // ignore: avoid_print
      print('TLS succeeded; HTTP ${response.statusCode}');
    },
    skip: Platform.environment['PRIME_TLS_URL'] == null,
  );
}
