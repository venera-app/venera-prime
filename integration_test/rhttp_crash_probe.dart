// Manual native crash probe; build/install an independent APK, never the user's app.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../test/support/rhttp_callback_cases.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('PRIME_RHTTP_CRASH_PROBE')) {
    throw StateError('Enable PRIME_RHTTP_CRASH_PROBE for this manual probe');
  }
  final status = ValueNotifier('Running native network regression');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, text, _) => Text(text),
          ),
        ),
      ),
    ),
  );
  final dir = await getExternalStorageDirectory();
  final log = File('${dir!.path}/rhttp-probe.log');
  void record(String text) {
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $text\n',
      mode: FileMode.append,
      flush: true,
    );
    status.value = text;
  }

  record('START pid=$pid');
  try {
    await runRhttpCallbackCases();
    record('PASS callback cancellation and invalid request regressions');
    await Future<void>.delayed(const Duration(seconds: 60));
    record('PASS idle 60s');
  } catch (error, stack) {
    record('FAIL $error\n$stack');
  }
}
