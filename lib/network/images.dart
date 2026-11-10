import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/file_type.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final data = await CacheManager().readCache(cacheKey);

    if (data != null) {
      if (detectFileType(data).mime.startsWith('image/')) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } else {
        await CacheManager().delete(cacheKey);
      }
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    if ((req.statusCode ?? 0) >= 400) {
      throw Exception("Invalid Status Code: ${req.statusCode}");
    }
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    final buffer = BytesBuilder(copy: false);
    var receivedBytes = 0;
    await for (var data in stream) {
      buffer.add(data);
      receivedBytes += data.length;
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: receivedBytes,
          totalBytes: expectedBytes,
        );
      }
    }

    var imageBytes = buffer.takeBytes();

    if (configs['onResponse'] is JSInvokable) {
      final result = (configs['onResponse'] as JSInvokable)([imageBytes]);
      if (result is! List<int>) {
        throw "Error: Invalid onResponse result.";
      }
      imageBytes = result is Uint8List ? result : Uint8List.fromList(result);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, imageBytes);
    yield ImageDownloadProgress(
      currentBytes: imageBytes.length,
      totalBytes: imageBytes.length,
      imageBytes: imageBytes,
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Invalidate both an in-flight download and its processed disk cache.
  static Future<void> invalidateComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async {
    final key = '$imageKey@$sourceKey@$cid@$eid';
    _loadingImages.remove(key)?.cancel();
    await CacheManager().delete(key);
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    late final _StreamWrapper<ImageDownloadProgress> stream;
    stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        isCurrent: () =>
            identical(_loadingImages[cacheKey], stream) && !stream.isClosed,
      ),
      (wrapper) {
        if (identical(_loadingImages[cacheKey], wrapper)) {
          _loadingImages.remove(cacheKey);
        }
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool cacheResult = true,
    bool useCache = true,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cacheResult: cacheResult,
      useCache: useCache,
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool cacheResult = true,
    bool useCache = true,
    bool Function()? isCurrent,
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final data = useCache ? await CacheManager().readCache(cacheKey) : null;

    if (data != null) {
      if (detectFileType(data).mime.startsWith('image/')) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } else {
        await CacheManager().delete(cacheKey);
      }
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
        );
        if ((req.statusCode ?? 0) >= 400) {
          throw Exception("Invalid Status Code: ${req.statusCode}");
        }
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        final buffer = BytesBuilder(copy: false);
        var receivedBytes = 0;
        await for (var data in stream) {
          buffer.add(data);
          receivedBytes += data.length;
          yield ImageDownloadProgress(
            currentBytes: receivedBytes,
            totalBytes: expectedBytes,
          );
        }

        var imageData = buffer.takeBytes();

        if (configs['onResponse'] is JSInvokable) {
          final callback = configs.remove('onResponse') as JSInvokable;
          try {
            dynamic result = callback([imageData]);
            if (result is Future) result = await result;
            if (result is! List<int>) throw "Error: Invalid onResponse result.";
            imageData = result is Uint8List
                ? result
                : Uint8List.fromList(result);
          } finally {
            callback.free();
          }
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            imageData,
            configs['modifyImage'],
          );
          imageData = newData;
        }

        if (!detectFileType(imageData).mime.startsWith('image/')) {
          throw const FormatException(
            'Image response or processing result is not an image',
          );
        }
        if (cacheResult && (isCurrent?.call() ?? true)) {
          await CacheManager().writeCache(cacheKey, imageData);
        }
        yield ImageDownloadProgress(
          currentBytes: imageData.length,
          totalBytes: imageData.length,
          imageBytes: imageData,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        Map<String, dynamic>? newConfig;
        try {
          newConfig = await onLoadFailed();
        } finally {
          (configs['onLoadFailed'] as JSInvokable).free();
          onLoadFailed = null;
        }
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
