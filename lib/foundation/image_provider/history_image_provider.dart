import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  HistoryImageProvider(this.history)
    : _key = "history${history.id}${history.type.value}${history.cover}";

  final History history;

  final String _key;

  Future<Uint8List> _loadThumbnail(String url, chunkEvents, checkStop) async {
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  String? _findFavoriteCover() {
    try {
      var folders = LocalFavoritesManager().find(history.id, history.type);
      if (folders.isEmpty) {
        return null;
      }
      return LocalFavoritesManager()
          .getComic(folders.first, history.id, history.type)
          .coverPath;
    } catch (_) {
      return null;
    }
  }

  Future<String> _refreshCoverFromSource() async {
    var comicSource =
        history.type.comicSource ?? (throw "Comic source not found.");
    var comic = await comicSource.loadComicInfo!(history.id);
    if (comic.error) {
      throw comic.errorMessage ?? "Failed to load comic info";
    }
    history.title = comic.data.title;
    history.subtitle = comic.data.subTitle ?? '';
    history.cover = comic.data.cover;
    HistoryManager().addHistory(history);
    return comic.data.cover;
  }

  void _saveCover(String cover) {
    if (cover.isEmpty || cover == history.cover) {
      return;
    }
    history.cover = cover;
    HistoryManager().addHistory(history);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
    }

    Object? lastError;
    var tried = <String>{};

    Future<Uint8List?> tryLoad(String? cover, {bool saveCover = false}) async {
      cover = cover?.trim();
      if (cover == null || cover.isEmpty || tried.contains(cover)) {
        return null;
      }
      tried.add(cover);
      try {
        var data = await _loadThumbnail(cover, chunkEvents, checkStop);
        if (saveCover) {
          _saveCover(cover);
        }
        return data;
      } catch (e) {
        lastError = e;
        return null;
      }
    }

    if (url.contains('/')) {
      var data = await tryLoad(url);
      if (data != null) {
        return data;
      }
    }

    var data = await tryLoad(_findFavoriteCover(), saveCover: true);
    if (data != null) {
      return data;
    }

    try {
      data = await tryLoad(await _refreshCoverFromSource());
      if (data != null) {
        return data;
      }
    } catch (e) {
      lastError = e;
    }

    data = await tryLoad(url);
    if (data != null) {
      return data;
    }

    throw lastError ?? "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => _key;
}
