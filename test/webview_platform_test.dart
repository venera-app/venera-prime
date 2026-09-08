import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/translations.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  _WebViewPlatform({required this.isAndroid});

  final bool isAndroid;
  int featureChecks = 0;

  @override
  PlatformWebViewFeature createPlatformWebViewFeatureStatic() {
    featureChecks++;
    if (isAndroid) return _UnsupportedProxyFeature();
    return super.createPlatformWebViewFeatureStatic();
  }

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);
}

class _UnsupportedProxyFeature extends PlatformWebViewFeature {
  _UnsupportedProxyFeature()
    : super.implementation(const PlatformWebViewFeatureCreationParams());

  @override
  Future<bool> isFeatureSupported(WebViewFeature feature) async {
    expect(feature, WebViewFeature.PROXY_OVERRIDE);
    return false;
  }
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: Key('native-webview'));

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    for (final proxy in ['system', 'direct', '127.0.0.1:8080']) {
      testWidgets('$platform with $proxy gates Android feature API', (
        tester,
      ) async {
        final originalPlatform = InAppWebViewPlatform.instance;
        final originalProxy = appdata.settings['proxy'];
        final backend = _WebViewPlatform(
          isAndroid: platform == TargetPlatform.android,
        );
        InAppWebViewPlatform.instance = backend;
        debugDefaultTargetPlatformOverride = platform;
        appdata.settings['proxy'] = proxy;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          if (originalPlatform != null) {
            InAppWebViewPlatform.instance = originalPlatform;
          }
          appdata.settings['proxy'] = originalProxy;
        });
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              home: const AppWebview(initialUrl: 'https://example.com/login'),
            ),
          );
          // The loading indicator animates until the native view loads; do not
          // pumpAndSettle against this deliberately inert native-view stub.
          await tester.pump();
          expect(
            backend.featureChecks,
            platform == TargetPlatform.android ? 1 : 0,
          );
          expect(find.byKey(const Key('native-webview')), findsOneWidget);
          expect(find.textContaining('UnimplementedError'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
