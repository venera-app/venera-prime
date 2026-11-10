import 'dart:async';
import 'dart:collection';

/// Retains launch intents until both startup and source initialization finish.
class PendingAppLinks {
  PendingAppLinks(this.open, this.onError);
  final Future<void> Function(Uri) open;
  final void Function(Object, StackTrace) onError;
  final _pending = Queue<Uri>();
  bool _ready = false;
  bool _opening = false;

  void add(Uri uri) {
    _pending.add(uri);
    unawaited(_drain());
  }

  void setReady(bool ready) {
    _ready = ready;
    if (ready) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_opening) return;
    _opening = true;
    try {
      while (_ready && _pending.isNotEmpty) {
        final uri = _pending.removeFirst();
        try {
          await open(uri);
        } catch (error, stack) {
          onError(error, stack);
        }
      }
    } finally {
      _opening = false;
    }
  }
}

/// Only strip a page suffix for known gallery URL structures, never a comic ID.
({Uri uri, int? page}) comicLinkTarget(Uri uri) {
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final host = uri.host.toLowerCase();
  final gallery = parts.isNotEmpty && parts.first == 'g';
  final knownPage =
      gallery &&
      ((host == 'nhentai.net' && parts.length == 3) ||
          ((host == 'e-hentai.org' || host == 'exhentai.org') &&
              parts.length == 4));
  final page = knownPage ? int.tryParse(parts.last) : null;
  if (page == null || page < 1 || int.tryParse(parts[1]) == null) {
    return (uri: uri, page: null);
  }
  return (
    uri: uri.replace(pathSegments: [...parts.take(parts.length - 1), '']),
    page: page,
  );
}
