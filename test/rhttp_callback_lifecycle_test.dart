import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/rhttp_callback_cases.dart';

void main() {
  test(
    'late response/error callbacks and invalid requests do not abort',
    runRhttpCallbackCases,
    skip: Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
