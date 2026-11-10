// Manual diagnostic APK: exercises actual Android VIEW intents without network sources.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/translations.dart';

late File log;
void record(String message) =>
    log.writeAsStringSync('$message\n', mode: FileMode.append, flush: true);

class _Source implements ComicSource {
  @override
  String get key => 'link-probe';
  @override
  String get name => 'Link probe';
  @override
  LinkHandler get linkHandler => LinkHandler(['nhentai.net'], (url) {
    final match = RegExp(r'^https://nhentai\.net/g/(\d+)/?$').firstMatch(url);
    record('PARSE $url -> ${match?.group(1)}');
    return match?.group(1);
  });
  @override
  get loadComicInfo =>
      (String id) async =>
          const Res<ComicDetails>.error('Probe: no network requested');
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Observer extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void inspect(Element element) {
        final widget = element.widget;
        if (widget is ComicPage) {
          record('OPEN id=${widget.id} page=${widget.initialReaderPage}');
        }
        element.visitChildren(inspect);
      }

      final context = App.rootNavigatorKey.currentContext;
      if (context is Element) inspect(context);
    });
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('PRIME_APP_LINK_PROBE')) {
    throw StateError('Opt-in required');
  }
  await App.init();
  App.dataPath = '${App.dataPath}/app-link-probe';
  Directory('${App.dataPath}/local').createSync(recursive: true);
  File('${App.dataPath}/local_path').writeAsStringSync('${App.dataPath}/local');
  log = File('${App.dataPath}/probe.log');
  record('START pid=$pid');
  await App.initComponents();
  await AppTranslation.init();
  final sources = Future<void>.delayed(const Duration(seconds: 3), () {
    ComicSourceManager().add(_Source());
    record('SOURCES READY');
  });
  handleLinks(sources);
  App.mainNavigatorKey = App.rootNavigatorKey;
  runApp(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      navigatorObservers: [_Observer()],
      home: const Scaffold(
        body: Center(child: Text('Waiting for Android VIEW intent')),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  setAppLinkNavigatorMounted(true);
  record('NAVIGATION READY');
  setAppLinkNavigationReady(true);
}
