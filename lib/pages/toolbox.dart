import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/translations.dart';

const _searchByImageBotUrl = 'https://soutubot.moe/';
const _sauceNaoUrl = 'https://saucenao.com/';

Future<void> showToolbox(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Theme.of(sheetContext).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: const _ToolboxSheet(),
          ),
        ),
      );
    },
  );
}

class _ToolboxSheet extends StatelessWidget {
  const _ToolboxSheet();

  @override
  Widget build(BuildContext context) {
    void closeThen(VoidCallback action) {
      Navigator.of(context).pop();
      Future.microtask(action);
    }

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(24, 8, 16, 4),
              title: Text(
                'Tools'.tl,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.image_search_outlined),
              title: Text('Image search [Search by Image Bot]'.tl),
              trailing: const Icon(Icons.open_in_new),
              onTap: () =>
                  closeThen(() => _openToolWebsite(_searchByImageBotUrl)),
            ),
            ListTile(
              leading: const Icon(Icons.image_search),
              title: Text('Image search [SauceNAO]'.tl),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => closeThen(() => _openToolWebsite(_sauceNaoUrl)),
            ),
          ],
        ),
      ),
    );
  }
}

bool _handleComicLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  for (final source in ComicSource.all()) {
    final handler = source.linkHandler;
    if (handler == null || !handler.domains.contains(uri.host)) continue;
    try {
      if (handler.linkToId(url) != null) {
        handleAppLink(uri);
        return true;
      }
    } catch (_) {
      return false;
    }
  }
  return false;
}

Future<void> _openToolWebsite(String url) async {
  if (App.isMobile || App.isMacOS) {
    App.mainNavigatorKey?.currentContext?.to(
      () => AppWebview(
        initialUrl: url,
        onNavigation: (url, _) => _handleComicLink(url),
      ),
    );
    return;
  }

  if (!await DesktopWebview.isAvailable()) {
    App.rootContext.showMessage(message: 'Webview is not available'.tl);
    return;
  }
  final webview = DesktopWebview(
    initialUrl: url,
    onNavigation: (url, webview) {
      if (_handleComicLink(url)) {
        Future.microtask(webview.close);
      }
    },
  );
  webview.open();
}
