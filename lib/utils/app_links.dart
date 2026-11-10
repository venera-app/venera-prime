import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'pending_app_links.dart';

StreamSubscription<Uri>? _subscription;
Future<void> _sourcesReady = Future.value();
bool _sourcesInitialized = false;
bool _navigationReady = false;
bool _navigatorMounted = false;
final _pending = PendingAppLinks((uri) async {
  await handleAppLink(uri);
}, (error, stack) => Log.error('App links', error, stack));

void setAppLinkNavigationReady(bool ready) {
  _navigationReady = ready;
  _updateReadiness();
}

void setAppLinkNavigatorMounted(bool mounted) {
  _navigatorMounted = mounted;
  _updateReadiness();
}

void _updateReadiness() => _pending.setReady(
  _navigationReady && _navigatorMounted && _sourcesInitialized,
);

void handleLinks(Future<void> sourcesReady) {
  _sourcesReady = sourcesReady;
  _sourcesInitialized = false;
  _pending.setReady(false);
  // app_links delivers the initial Android intent through this stream too.
  // Subscribe once, including when initialization is retried.
  _subscription ??= AppLinks().uriLinkStream.listen(
    _pending.add,
    onError: (Object error, StackTrace stack) =>
        Log.error('App links', error, stack),
  );
  unawaited(
    sourcesReady.then(
      (_) {
        _sourcesInitialized = true;
        _updateReadiness();
      },
      onError: (Object error, StackTrace stack) {
        Log.error('App links source initialization', error, stack);
      },
    ),
  );
}

Future<bool> handleAppLink(Uri uri) async {
  try {
    await _sourcesReady;
  } catch (error, stack) {
    Log.error('App links source initialization', error, stack);
    return false;
  }
  final target = comicLinkTarget(uri);
  for (final source in ComicSource.all()) {
    final handler = source.linkHandler;
    if (handler == null ||
        !handler.domains.any(
          (domain) => domain.toLowerCase() == uri.host.toLowerCase(),
        )) {
      continue;
    }
    try {
      final id = handler.linkToId(target.uri.toString());
      if (id == null || id.isEmpty) continue;
      // Reader/settings routes live above the nested home navigator. A link
      // must open above the visible route instead of behind that overlay.
      final context = App.rootNavigatorKey.currentState?.canPop() == true
          ? App.rootNavigatorKey.currentContext
          : App.mainNavigatorKey?.currentContext;
      if (context == null || !context.mounted) return false;
      unawaited(
        context.to(
          () => ComicPage(
            id: id,
            sourceKey: source.key,
            initialReaderPage: target.page,
          ),
        ),
      );
      return true;
    } catch (error, stack) {
      Log.error('App links (${source.key})', error, stack);
    }
  }
  return false;
}
