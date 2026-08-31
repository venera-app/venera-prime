import 'dart:async';

import 'package:dio/io.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final int maxConcurrent;

  FileDownloader(this.url, this.savePath, {this.maxConcurrent = 4});

  int _currentBytes = 0;

  int _lastBytes = 0;

  late int _fileSize;
  bool _rangeSupported = true;

  final _dio = Dio();

  RandomAccessFile? _file;

  bool _isWriting = false;

  int _kChunkSize = 16 * 1024 * 1024;

  bool _canceled = false;

  Timer? _progressTimer;

  final _activeDownloads = <Future<void>>{};

  late List<_DownloadBlock> _blocks;

  Future<void> _writeStatus() async {
    var file = File("$savePath.download");
    await file.writeAsString(_blocks.map((e) => e.toString()).join("\n"));
  }

  Future<void> _readStatus() async {
    var file = File("$savePath.download");
    if (!await file.exists()) {
      return;
    }

    var lines = await file.readAsLines();
    try {
      _blocks = lines.map((e) => _DownloadBlock.fromString(e)).toList();
      if (_blocks.isEmpty ||
          _blocks.any(
            (block) =>
                block.start < 0 ||
                block.start >= block.end ||
                block.end > _fileSize ||
                block.downloadedBytes < 0 ||
                block.downloadedBytes > block.end - block.start,
          ) ||
          _blocks.first.start != 0 ||
          _blocks.last.end != _fileSize ||
          _blocks.asMap().entries.any(
            (entry) =>
                entry.key > 0 &&
                _blocks[entry.key - 1].end != entry.value.start,
          )) {
        throw const FormatException('Invalid download state');
      }
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }

  /// create file and write empty bytes
  Future<void> _prepareFile() async {
    var file = File(savePath);
    if (await file.exists()) {
      if (file.lengthSync() == _fileSize &&
          File("$savePath.download").existsSync()) {
        _file = await file.open(mode: FileMode.append);
        return;
      } else {
        await file.delete();
      }
    }

    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.append);
    await _file!.truncate(_fileSize);
  }

  Future<void> _createTasks() async {
    var res = await _dio.head(url);
    if (res.statusCode == null ||
        res.statusCode! < 200 ||
        res.statusCode! >= 400) {
      throw Exception('Download HEAD failed with status ${res.statusCode}');
    }
    var length = res.headers["content-length"]?.first;
    _fileSize = int.tryParse(length ?? '') ?? 0;
    if (_fileSize <= 0) {
      throw Exception('Download response has no valid Content-Length');
    }
    _rangeSupported =
        res.headers.value('accept-ranges')?.toLowerCase() == 'bytes';

    await _prepareFile();

    if (File("$savePath.download").existsSync()) {
      await _readStatus();
      _currentBytes = _blocks.fold<int>(
        0,
        (previousValue, element) => previousValue + element.downloadedBytes,
      );
    } else {
      if (_fileSize > 1024 * 1024 * 1024) {
        _kChunkSize = 64 * 1024 * 1024;
      } else if (_fileSize > 512 * 1024 * 1024) {
        _kChunkSize = 32 * 1024 * 1024;
      }

      _blocks = [];
      for (var i = 0; i < _fileSize; i += _kChunkSize) {
        var end = i + _kChunkSize;
        if (end > _fileSize) {
          _blocks.add(_DownloadBlock(i, _fileSize, 0, false));
        } else {
          _blocks.add(_DownloadBlock(i, i + _kChunkSize, 0, false));
        }
      }
    }
  }

  Stream<DownloadingStatus> start() {
    var stream = StreamController<DownloadingStatus>();
    _download(stream);
    return stream.stream;
  }

  void _reportStatus(StreamController<DownloadingStatus> stream) {
    stream.add(DownloadingStatus(_currentBytes, _fileSize, 0));
  }

  void _download(StreamController<DownloadingStatus> resultStream) async {
    try {
      var proxy = await getProxy();
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          return HttpClient()
            ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
        },
      );

      // get file size
      await _createTasks();

      if (_canceled) {
        await _file?.close();
        _file = null;
        resultStream.close();
        return;
      }

      if (!_rangeSupported) {
        await _downloadSingleStream();
        await _file?.close();
        _file = null;
        if (_canceled) {
          resultStream.close();
          return;
        }
        await File("$savePath.download").deleteIfExists();
        resultStream.add(DownloadingStatus(_fileSize, _fileSize, 0, true));
        resultStream.close();
        return;
      }

      // check if file is downloaded
      if (_currentBytes >= _fileSize) {
        await _file!.close();
        _file = null;
        _reportStatus(resultStream);
        resultStream.close();
        return;
      }

      _reportStatus(resultStream);

      _progressTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_canceled || _currentBytes >= _fileSize) {
          timer.cancel();
          return;
        }
        resultStream.add(
          DownloadingStatus(
            _currentBytes,
            _fileSize,
            _currentBytes - _lastBytes,
          ),
        );
        _lastBytes = _currentBytes;
      });

      // start downloading
      await _scheduleDownload();
      if (_canceled) {
        await _file?.close();
        _file = null;
        resultStream.close();
        return;
      }
      final complete =
          _blocks.isNotEmpty &&
          _blocks.every(
            (block) => block.downloadedBytes == block.end - block.start,
          );
      await _file!.close();
      _file = null;
      final actualLength = await File(savePath).length();

      // check if download is finished
      if (!complete || _currentBytes < _fileSize || actualLength != _fileSize) {
        resultStream.addError(
          Exception(
            "Download failed: Expected $_fileSize bytes, "
            "but only $_currentBytes bytes downloaded.",
          ),
        );
        resultStream.close();
        return;
      }

      await File("$savePath.download").delete();
      resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
      resultStream.close();
    } catch (e, s) {
      await _file?.close();
      _file = null;
      resultStream.addError(e, s);
      resultStream.close();
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
    }
  }

  Future<void> _downloadSingleStream() async {
    await _file?.close();
    _file = null;
    await File(savePath).deleteIfExists();
    await File('$savePath.download').deleteIfExists();
    final file = File(savePath);
    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.write);
    _currentBytes = 0;
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream),
    );
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300 ||
        response.data == null) {
      throw Exception(
        'Single-stream download failed with status ${response.statusCode}',
      );
    }
    await for (final chunk in response.data!.stream) {
      if (_canceled) return;
      await _file!.writeFrom(chunk);
      _currentBytes += chunk.length;
    }
    if (_currentBytes != _fileSize) {
      throw Exception(
        'Download size mismatch: expected $_fileSize, got $_currentBytes',
      );
    }
  }

  Future<void> _scheduleDownload() async {
    var tasks = <Future>[];
    while (true) {
      if (_canceled) return;
      if (tasks.length >= maxConcurrent) {
        await Future.any(tasks);
      }
      final block = _blocks.firstWhereOrNull(
        (element) =>
            !element.downloading &&
            element.end - element.start > element.downloadedBytes,
      );
      if (block == null) {
        break;
      }
      block.downloading = true;
      var task = _fetchBlock(block);
      _activeDownloads.add(task);
      task.then(
        (_) {
          tasks.remove(task);
          _activeDownloads.remove(task);
        },
        onError: (Object error, StackTrace stack) {
          tasks.remove(task);
          _activeDownloads.remove(task);
        },
      );
      tasks.add(task);
    }
    await Future.wait(tasks);
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start;
    final end = block.end;

    if (start > _fileSize) {
      return;
    }

    var options = Options(
      responseType: ResponseType.stream,
      headers: {
        "Range": "bytes=${start + block.downloadedBytes}-${end - 1}",
        "Accept": "*/*",
        "Accept-Encoding": "deflate, gzip",
      },
      preserveHeaderCase: true,
    );
    final res = await _dio.get<ResponseBody>(url, options: options);
    if (_canceled) return;
    final expectedStart = start + block.downloadedBytes;
    final expectedLength = end - expectedStart;
    if (res.statusCode != 206 || res.data == null) {
      throw Exception(
        'Range request failed: expected 206, got ${res.statusCode}',
      );
    }
    final range = res.headers.value('content-range');
    final match = range == null
        ? null
        : RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(range);
    if (match == null ||
        int.parse(match.group(1)!) != expectedStart ||
        int.parse(match.group(2)!) != end - 1 ||
        (match.group(3) != '*' && int.parse(match.group(3)!) != _fileSize)) {
      throw Exception('Invalid Content-Range for block $expectedStart-$end');
    }
    final contentLength = res.headers.value('content-length');
    if (contentLength != null &&
        int.tryParse(contentLength) != expectedLength) {
      throw Exception('Invalid Content-Length for block $expectedStart-$end');
    }

    var buffer = <int>[];
    var received = 0;
    Future<void> flushBuffer() async {
      if (buffer.isEmpty) return;
      while (_isWriting) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      _isWriting = true;
      try {
        if (received + buffer.length > expectedLength) {
          throw Exception('Range response exceeded requested length');
        }
        await _file!.setPosition(expectedStart + received);
        await _file!.writeFrom(buffer);
        received += buffer.length;
        _currentBytes += buffer.length;
        buffer = <int>[];
        await _writeStatus();
      } finally {
        _isWriting = false;
      }
    }

    try {
      await for (var data in res.data!.stream) {
        if (_canceled) return;
        buffer.addAll(data);
        if (buffer.length >= 16 * 1024) await flushBuffer();
      }
      await flushBuffer();
      if (received != expectedLength) {
        throw Exception(
          'Range response length mismatch: expected $expectedLength, got $received',
        );
      }
      block.downloadedBytes += received;
    } finally {
      block.downloading = false;
    }
  }

  Future<void> stop() async {
    _canceled = true;
    await Future.wait(
      List<Future<void>>.from(_activeDownloads),
      eagerError: false,
    );
    await _file?.close();
    _file = null;
  }
}

class DownloadingStatus {
  /// The current downloaded bytes
  final int downloadedBytes;

  /// The total bytes of the file
  final int totalBytes;

  /// Whether the download is finished
  final bool isFinished;

  /// The download speed in bytes per second
  final int bytesPerSecond;

  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  @override
  String toString() {
    return "Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}";
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;
  bool downloading;

  _DownloadBlock(this.start, this.end, this.downloadedBytes, this.downloading);

  @override
  String toString() {
    return "$start-$end-$downloadedBytes";
  }

  _DownloadBlock.fromString(String str)
    : start = int.parse(str.split("-")[0]),
      end = int.parse(str.split("-")[1]),
      downloadedBytes = int.parse(str.split("-")[2]),
      downloading = false;
}
