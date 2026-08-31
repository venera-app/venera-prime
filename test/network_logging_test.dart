import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  test('network log URLs redact credentials and authentication parameters', () {
    final safe = MyLogInterceptor.safeUrl(
      'https://user:password@example.test/path?token=abc&x-auth-signature=def&query=visible',
    );

    expect(safe, contains('https://example.test/path'));
    expect(safe, contains('token=%2A'));
    expect(safe, contains('x-auth-signature=%2A'));
    expect(safe, contains('query=visible'));
    expect(safe, isNot(contains('user')));
    expect(safe, isNot(contains('password')));
    expect(safe, isNot(contains('abc')));
    expect(safe, isNot(contains('def')));
  });
}
