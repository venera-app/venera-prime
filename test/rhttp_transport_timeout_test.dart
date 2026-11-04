import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  test(
    'native requests time out or cancel while waiting for headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finishPartialResponse = Completer<void>();
      final subscription = server.listen((request) async {
        if (request.uri.path == '/hang') {
          return;
        }
        if (request.uri.path == '/partial') {
          request.response.write('first');
          await request.response.flush();
          await finishPartialResponse.future;
          request.response.write('rest');
          await request.response.close();
          return;
        }
        if (request.uri.path == '/slow-upload') {
          await request.drain<void>();
          request.response.write('uploaded');
          await request.response.close();
          return;
        }
        if (request.uri.path == '/early') {
          request.response.write('early');
          await request.response.close();
          return;
        }
        request.response.write('ok');
        await request.response.close();
      });
      final previousProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final dio = AppDio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 2),
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(milliseconds: 150),
          responseType: ResponseType.plain,
        ),
      );
      final baseUrl = 'http://127.0.0.1:${server.port}';
      try {
        await expectLater(
          dio.get<String>('$baseUrl/hang'),
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.receiveTimeout,
            ),
          ),
        );

        await expectLater(
          dio.get<String>('$baseUrl/partial'),
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.receiveTimeout,
            ),
          ),
        );

        final cancelToken = CancelToken();
        final cancelled = dio.get<String>(
          '$baseUrl/hang',
          cancelToken: cancelToken,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        cancelToken.cancel('test cancellation');
        await expectLater(
          cancelled,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );

        final stalledBody = Stream<Uint8List>.multi((controller) {
          controller.add(Uint8List.fromList([1]));
        });
        final uploadDio = AppDio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 2),
            sendTimeout: const Duration(milliseconds: 150),
            receiveTimeout: const Duration(seconds: 2),
          ),
        );
        try {
          await expectLater(
            uploadDio.post<void>('$baseUrl/hang', data: stalledBody),
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                'type',
                DioExceptionType.sendTimeout,
              ),
            ),
          );

          final earlyBody = Stream<Uint8List>.multi((controller) {
            controller.add(Uint8List.fromList([1]));
            Timer(const Duration(milliseconds: 50), controller.close);
          });
          expect(
            await uploadDio
                .post<String>(
                  '$baseUrl/early',
                  data: earlyBody,
                  options: Options(responseType: ResponseType.plain),
                )
                .timeout(const Duration(seconds: 1))
                .then((response) => response.data),
            'early',
          );
        } finally {
          uploadDio.close(force: true);
        }

        expect(await dio.get<String>('$baseUrl/ok').then((r) => r.data), 'ok');

        final slowUploadDio = AppDio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 2),
            sendTimeout: const Duration(milliseconds: 250),
            receiveTimeout: const Duration(milliseconds: 100),
            responseType: ResponseType.plain,
          ),
        );
        final slowBody = Stream<Uint8List>.multi((controller) {
          var sentChunks = 0;
          void sendNext() {
            controller.add(Uint8List(16 * 1024));
            sentChunks++;
            if (sentChunks == 4) {
              controller.close();
            } else {
              Timer(const Duration(milliseconds: 60), sendNext);
            }
          }

          sendNext();
        });
        try {
          expect(
            await slowUploadDio
                .post<String>('$baseUrl/slow-upload', data: slowBody)
                .then((response) => response.data),
            'uploaded',
          );
        } finally {
          slowUploadDio.close(force: true);
        }

        final refused = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final refusedPort = refused.port;
        await refused.close();
        final stopwatch = Stopwatch()..start();
        final refusedBody = Stream<Uint8List>.multi((controller) {
          controller.add(Uint8List.fromList([1]));
        });
        await expectLater(
          dio.post<void>('http://127.0.0.1:$refusedPort/', data: refusedBody),
          throwsA(isA<DioException>()),
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      } finally {
        if (!finishPartialResponse.isCompleted) {
          finishPartialResponse.complete();
        }
        dio.close(force: true);
        appdata.settings['proxy'] = previousProxy;
        await server.close(force: true);
        await subscription.cancel();
      }
    },
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
