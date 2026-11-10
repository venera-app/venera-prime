import 'dart:async';
import 'dart:io';

import 'package:rhttp/rhttp.dart' as rhttp;
// Exercise the real bridge, including delayed Dart acknowledgements. Mocking
// RhttpClient cannot reproduce a panic in frb_dart_fn_deliver_output.
import 'package:rhttp/src/rust/api/client.dart' as native_client;
import 'package:rhttp/src/rust/api/http.dart' as native_http;
import 'package:rhttp/src/rust/lib.dart' as native_lib;

Future<void> runRhttpCallbackCases() async {
  await rhttp.Rhttp.init();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverSubscription = server.listen((request) async {
    request.response.write('ok');
    await request.response.close();
  });
  final closedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final closedPort = closedServer.port;
  await closedServer.close(force: true);
  final url = 'http://127.0.0.1:${server.port}/';
  try {
    for (final failConnection in [false, true]) {
      for (final cancelClient in [false, true]) {
        for (var iteration = 0; iteration < 5; iteration++) {
          final client = await native_http.registerClient(
            settings: const native_client.ClientSettings(
              httpVersionPref: native_http.HttpVersionPref.all,
              throwOnStatusCode: false,
              proxySettings: native_client.ProxySettings.noProxy(),
            ),
          );
          final entered = Completer<void>();
          final release = Completer<void>();
          final cancelled = Completer<void>();
          final token = Completer<native_lib.CancellationToken>();
          final done = Completer<void>();
          final stream = native_http
              .makeHttpRequestReceiveStream(
                client: client,
                method: const native_http.HttpMethod(method: 'GET'),
                url: failConnection ? 'http://127.0.0.1:$closedPort/' : url,
                cancelable: true,
                onCancelToken: token.complete,
                onResponse: (_) async {
                  entered.complete();
                  await release.future;
                },
                onError: (_) async {
                  if (failConnection && !entered.isCompleted) {
                    entered.complete();
                    await release.future;
                  } else if (!cancelled.isCompleted) {
                    cancelled.complete();
                  }
                },
              )
              .listen((_) {}, onError: (Object _) {}, onDone: done.complete);
          try {
            await entered.future.timeout(const Duration(seconds: 5));
            if (cancelClient) {
              await native_http.cancelRunningRequests(client: client);
            } else {
              await native_http.cancelRequest(token: await token.future);
            }
            await cancelled.future.timeout(const Duration(seconds: 5));
            release.complete();
            await done.future.timeout(const Duration(seconds: 5));
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await _checkHealthy(url);
          } finally {
            if (!release.isCompleted) release.complete();
            await stream.cancel();
            client.dispose();
          }
        }
      }
    }
    await _expectRequestError(
      rhttp.Rhttp.getText(
        'http://callback-test.invalid/',
        settings: rhttp.ClientSettings(
          proxySettings: const rhttp.ProxySettings.noProxy(),
          dnsSettings: rhttp.DnsSettings.dynamic(
            resolver: (_) async => throw StateError('resolver failure'),
          ),
        ),
      ),
    );
    // Untrusted source scripts can supply these values. They must produce
    // request errors, never native panics, and later requests must still work.
    for (final method in ['', 'BAD METHOD', 'GET\r\nInjected: yes']) {
      await _expectRequestError(
        rhttp.Rhttp.request(
          method: rhttp.HttpMethod(method),
          url: url,
          expectBody: rhttp.HttpExpectBody.text,
        ),
      );
    }
    await _expectRequestError(
      native_http.makeHttpRequest(
        method: const native_http.HttpMethod(method: 'POST'),
        url: url,
        body: const native_http.HttpBody.bytesStream(),
        expectBody: native_http.HttpExpectBody.text,
        onCancelToken: (_) {},
        cancelable: false,
      ),
    );
    await _checkHealthy(url);
  } finally {
    await server.close(force: true);
    await serverSubscription.cancel();
  }
}

Future<void> _checkHealthy(String url) async {
  final response = await rhttp.Rhttp.getText(url);
  if (response.body != 'ok') {
    throw StateError('Unexpected response after cancellation');
  }
}

Future<void> _expectRequestError(Future<Object?> request) async {
  try {
    await request.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    rethrow;
  } catch (_) {
    return;
  }
  throw StateError('Invalid request unexpectedly succeeded');
}
