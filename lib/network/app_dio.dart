import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

Future<void>? _rHttpInitialization;

/// All rhttp users share one retryable initialization barrier.
///
/// Startup work is intentionally deferred, so requests from widgets, sync, or
/// comic-source hooks may otherwise reach the native bridge first.
Future<void> ensureRHttpInitialized() =>
    _rHttpInitialization ??= _initializeRHttp();

Future<void> _initializeRHttp() async {
  try {
    await rhttp.Rhttp.init();
  } catch (_) {
    _rHttpInitialization = null;
    rethrow;
  }
}

class MyLogInterceptor implements Interceptor {
  static const _sensitiveNames = {
    'authorization',
    'cookie',
    'set-cookie',
    'password',
    'passwd',
    'token',
    'access_token',
    'refresh_token',
    'client_secret',
    'secret',
    'signature',
    'x-auth-signature',
    'x-auth-timestamp',
    'umstring',
    'deviceinfo',
    'pseudoid',
  };

  static bool _isSensitive(String key) =>
      _sensitiveNames.contains(key.toLowerCase()) ||
      key.toLowerCase().contains('token') ||
      key.toLowerCase().contains('signature') ||
      key.toLowerCase().contains('password') ||
      key.toLowerCase().contains('secret');

  static String _safeUri(Uri uri) {
    final query = <String, String>{};
    uri.queryParameters.forEach((key, value) {
      query[key] = _isSensitive(key) ? '********' : value;
    });
    return uri.replace(userInfo: '', queryParameters: query).toString();
  }

  static String safeUrl(String value) {
    try {
      return _safeUri(Uri.parse(value));
    } catch (_) {
      return '<invalid url>';
    }
  }

  static Map<Object?, Object?> _safeMap(Map<Object?, Object?> map) => map.map(
    (key, value) => MapEntry(
      key,
      key is String && _isSensitive(key) ? '********' : _safeValue(value),
    ),
  );

  static Object? _safeValue(Object? value) {
    if (value is Map<Object?, Object?>) return _safeMap(value);
    if (value is List) return value.map(_safeValue).toList();
    final string = value?.toString() ?? 'null';
    return string.length > 4096 ? '${string.substring(0, 4096)}…' : string;
  }

  static Map<String, Object?> _safeHeaders(
    Map<String, dynamic> headers,
    Set<String> extra,
  ) => headers.map(
    (key, value) => MapEntry(
      key,
      _isSensitive(key) || extra.contains(key.toLowerCase())
          ? '********'
          : _safeValue(value),
    ),
  );

  static String _bodySummary(Object? body) {
    if (body == null) return '<empty body>';
    final length = body is List<int> ? body.length : body.toString().length;
    return '<body omitted, length: $length>';
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error(
      "Network",
      "${err.requestOptions.method} ${_safeUri(err.requestOptions.uri)}\n"
          "${err.type}: ${err.message}\n"
          "${_bodySummary(err.response?.data)}",
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final responseHeaders = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    final headers = _safeHeaders(responseHeaders, const <String>{});
    final content = _bodySummary(response.data);
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      "Response ${_safeUri(response.realUri)} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String dataMask = "****** DATA_PROTECTED ******";
    final extraMasks = (options.extra["maskHeadersInLog"] is Iterable)
        ? (options.extra["maskHeadersInLog"] as Iterable)
              .whereType<String>()
              .map((e) => e.toLowerCase())
              .toSet()
        : <String>{};
    Log.info(
      "Network",
      "${options.method} ${_safeUri(options.uri)}\n"
          "headers:\n${_safeHeaders(options.headers, extraMasks)}\n"
          "data:\n${options.extra["maskDataInLog"] == true ? dataMask : _safeValue(options.data)}",
    );
    options.connectTimeout ??= const Duration(seconds: 15);
    options.receiveTimeout ??= const Duration(seconds: 15);
    options.sendTimeout ??= const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio extends DioForNative {
  AppDio([super.baseOptions]) {
    httpClientAdapter = RHttpAdapter();
    if (App.isInitialized) {
      final cookieJar = SingleInstanceCookieJar.instance;
      if (cookieJar != null) {
        interceptors.add(CookieManagerSql(cookieJar));
      }
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, Future<void>> _requests = {};

  static Object? _keyValue(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return {
        for (final entry in entries)
          entry.key.toString(): _keyValue(entry.value),
      };
    }
    if (value is List<int>) {
      var hash = 0x811c9dc5;
      for (final byte in value) {
        hash ^= byte;
        hash = (hash * 0x01000193) & 0x7fffffff;
      }
      return '<bytes:${value.length}:$hash>';
    }
    if (value is Iterable) return value.map(_keyValue).toList();
    return value?.toString();
  }

  static String _requestKeyValue(Object? value) {
    try {
      return jsonEncode(_keyValue(value));
    } catch (_) {
      return value.toString();
    }
  }

  String _requestKey(
    String path,
    Map<String, dynamic>? queryParameters,
    Object? data,
    Options options,
  ) {
    final parsed = Uri.parse(path);
    final requestUri = parsed.hasScheme
        ? parsed
        : Uri.parse(this.options.baseUrl).resolve(path);
    final query = <String, List<String>>{
      for (final entry in requestUri.queryParametersAll.entries)
        entry.key: List<String>.from(entry.value),
    };
    queryParameters?.forEach((key, value) {
      query.putIfAbsent(key, () => <String>[]).add(value.toString());
    });
    final sortedQuery = query.keys.toList()..sort();
    final canonicalQuery = <String, dynamic>{
      for (final key in sortedQuery) key: query[key],
    };
    final headers = <String, dynamic>{};
    for (final entry
        in options.headers?.entries ?? const <MapEntry<String, dynamic>>[]) {
      if (entry.key.toLowerCase() != 'prevent-parallel') {
        headers[entry.key.toLowerCase()] = entry.value;
      }
    }
    return '${options.method ?? 'GET'}:${requestUri.replace(queryParameters: {}).toString()}'
        ':${_requestKeyValue(canonicalQuery)}'
        ':${_requestKeyValue(data)}:${_requestKeyValue(headers)}';
  }

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final requestOptions = options ?? Options();
    final prevent =
        requestOptions.headers?.entries.any(
          (entry) =>
              entry.key.toLowerCase() == 'prevent-parallel' &&
              entry.value.toString().toLowerCase() == 'true',
        ) ??
        false;
    requestOptions.headers?.removeWhere(
      (key, _) => key.toLowerCase() == 'prevent-parallel',
    );
    final key = _requestKey(path, queryParameters, data, requestOptions);
    Completer<void>? gate;
    if (prevent) {
      while (_requests.containsKey(key)) {
        await _requests[key];
      }
      gate = Completer<void>();
      _requests[key] = gate.future;
    }
    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: requestOptions,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (gate != null && identical(_requests[key], gate.future)) {
        _requests.remove(key);
        gate.complete();
      }
    }
  }
}

class RHttpAdapter implements HttpClientAdapter {
  static String? _clientSettingsKey;
  static Future<rhttp.RhttpClient>? _sharedClient;

  Future<rhttp.RhttpClient> _getClient() async {
    final proxy = await getProxy();
    final overrides = _getOverrides();
    final hosts = overrides.keys.toList()..sort();
    final sni = appdata.settings['sni'] != false;
    final verifyCertificates = appdata.settings['ignoreBadCertificate'] != true;
    final key = jsonEncode([
      proxy,
      sni,
      verifyCertificates,
      {for (final host in hosts) host: overrides[host]},
    ]);
    if (_clientSettingsKey == key && _sharedClient != null) {
      return _sharedClient!;
    }

    final settings = rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: overrides),
      tlsSettings: rhttp.TlsSettings(
        sni: sni,
        verifyCertificates: verifyCertificates,
      ),
    );
    final client = rhttp.RhttpClient.create(settings: settings);
    _clientSettingsKey = key;
    _sharedClient = client;
    // A source/image request creates its own AppDio. Share the native client
    // so those requests can reuse TCP/TLS connections. Dropping the old client
    // on a settings change lets rhttp release it when no request retains it;
    // disposing it here could interrupt an in-flight response stream.
    try {
      return await client;
    } catch (_) {
      if (identical(_sharedClient, client)) {
        _sharedClient = null;
        _clientSettingsKey = null;
      }
      rethrow;
    }
  }

  static Map<String, List<String>> _getOverrides() {
    if (appdata.settings['enableDnsOverrides'] != true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await ensureRHttpInitialized();
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    final cancelToken = rhttp.CancelToken();
    var cancelled = false;
    var sendTimedOut = false;
    final cancellation = cancelFuture?.then((_) {
      cancelled = true;
      _cancelRequest(cancelToken);
    });

    final requestSent = Completer<void>();
    void Function()? stopBodyStream;
    Stream<Uint8List>? bodyStream = requestStream;
    if (bodyStream == null) {
      requestSent.complete();
    } else {
      bodyStream = bodyStream.transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleData: (data, sink) => sink.add(data),
          handleError: (error, stackTrace, sink) {
            if (!requestSent.isCompleted) requestSent.complete();
            sink.addError(error, stackTrace);
          },
          handleDone: (sink) {
            if (!requestSent.isCompleted) requestSent.complete();
            sink.close();
          },
        ),
      );
    }
    final sendTimeout = options.sendTimeout;
    if (bodyStream != null && _hasTimeout(sendTimeout)) {
      bodyStream = _withSendIdleTimeout(
        bodyStream,
        sendTimeout!,
        options,
        (cleanup) => stopBodyStream = cleanup,
        () {
          sendTimedOut = true;
          if (!requestSent.isCompleted) requestSent.complete();
          _cancelRequest(cancelToken);
        },
      );
    }

    final Future<rhttp.HttpResponse> request = () async {
      final client = await _getClient();
      return client.request(
        method: rhttp.HttpMethod(options.method),
        url: options.uri.toString(),
        expectBody: rhttp.HttpExpectBody.stream,
        body: bodyStream == null ? null : rhttp.HttpBody.stream(bodyStream),
        headers: rhttp.HttpHeaders.rawMap(
          Map.fromEntries(
            options.headers.entries.map(
              (e) => MapEntry(e.key, e.value.toString().trim()),
            ),
          ),
        ),
        cancelToken: cancelToken,
      );
    }();
    request.then<void>(
      (_) => stopBodyStream?.call(),
      onError: (Object _, StackTrace __) => stopBodyStream?.call(),
    );

    rhttp.HttpResponse res;
    try {
      res = await _awaitTransportResponse(
        request,
        requestSent: requestSent.future,
        options: options,
        cancelFuture: cancellation,
        cancelToken: cancelToken,
      );
    } catch (error, stackTrace) {
      if (sendTimedOut) {
        Error.throwWithStackTrace(
          DioException.sendTimeout(
            timeout: sendTimeout!,
            requestOptions: options,
          ),
          stackTrace,
        );
      }
      if (cancelled) {
        Error.throwWithStackTrace(
          DioException.requestCancelled(
            requestOptions: options,
            reason: 'Request cancelled',
          ),
          stackTrace,
        );
      }
      rethrow;
    }
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    final receiveTimeout = options.receiveTimeout;
    final responseStream = _hasTimeout(receiveTimeout)
        ? _withReceiveIdleTimeout(
            res.body,
            receiveTimeout!,
            options,
            cancelToken,
          )
        : res.body;
    return ResponseBody(
      responseStream,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static bool _hasTimeout(Duration? timeout) =>
      timeout != null && timeout > Duration.zero;

  static void _cancelRequest(rhttp.CancelToken token) {
    // The caller already receives the timeout/cancellation error. Native
    // teardown must not produce a second, unhandled asynchronous exception.
    unawaited(token.cancel().catchError((Object _) {}));
  }

  static void _cancelStream(StreamSubscription<Uint8List>? subscription) {
    final cancellation = subscription?.cancel();
    if (cancellation != null) {
      unawaited(cancellation.catchError((Object _) {}));
    }
  }

  static Stream<Uint8List> _withReceiveIdleTimeout(
    Stream<Uint8List> source,
    Duration timeout,
    RequestOptions options,
    rhttp.CancelToken cancelToken,
  ) => Stream<Uint8List>.multi((controller) {
    Timer? idleTimer;
    StreamSubscription<Uint8List>? subscription;
    var finished = false;
    var outputClosed = false;
    var paused = false;

    void closeOutput() {
      if (outputClosed) return;
      outputClosed = true;
      controller.close();
    }

    void cancelResponseRequest() {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      _cancelRequest(cancelToken);
      if (paused) {
        paused = false;
        subscription?.resume();
      }
    }

    void armTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(timeout, () {
        if (finished) return;
        finished = true;
        controller.addError(
          DioException.receiveTimeout(
            timeout: timeout,
            requestOptions: options,
          ),
        );
        closeOutput();
        _cancelRequest(cancelToken);
        if (paused) {
          paused = false;
          subscription?.resume();
        }
      });
    }

    controller.onPause = () {
      paused = true;
      idleTimer?.cancel();
      subscription?.pause();
    };
    controller.onResume = () {
      paused = false;
      subscription?.resume();
      if (!finished) armTimer();
    };
    // Keep consuming the native stream after cancellation so its terminal
    // cancellation event is observed by this listener instead of escaping the
    // Rust bridge as an unhandled stream error.
    controller.onCancel = cancelResponseRequest;
    armTimer();
    subscription = source.listen(
      (chunk) {
        if (finished) return;
        armTimer();
        controller.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (finished) return;
        finished = true;
        idleTimer?.cancel();
        controller.addError(error, stackTrace);
        closeOutput();
      },
      onDone: () {
        if (finished) return;
        finished = true;
        idleTimer?.cancel();
        closeOutput();
      },
      cancelOnError: false,
    );
  });

  static Stream<Uint8List> _withSendIdleTimeout(
    Stream<Uint8List> source,
    Duration timeout,
    RequestOptions options,
    void Function(void Function()) onCleanupReady,
    void Function() onTimeout,
  ) => Stream<Uint8List>.multi((controller) {
    Timer? idleTimer;
    StreamSubscription<Uint8List>? subscription;
    var finished = false;
    var outputClosed = false;
    var cleaned = false;

    void closeOutput() {
      if (outputClosed) return;
      outputClosed = true;
      controller.close();
    }

    void cleanup() {
      if (cleaned) return;
      cleaned = true;
      finished = true;
      idleTimer?.cancel();
      _cancelStream(subscription);
      closeOutput();
    }

    void armTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(timeout, () {
        if (finished) return;
        onTimeout();
        controller.addError(
          DioException.sendTimeout(timeout: timeout, requestOptions: options),
        );
        closeOutput();
        cleanup();
      });
    }

    controller.onPause = () => subscription?.pause();
    controller.onResume = () => subscription?.resume();
    controller.onCancel = cleanup;
    onCleanupReady(cleanup);
    armTimer();
    subscription = source.listen(
      (chunk) {
        if (finished) return;
        armTimer();
        controller.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (finished) return;
        finished = true;
        idleTimer?.cancel();
        controller.addError(error, stackTrace);
        closeOutput();
        cleanup();
      },
      onDone: () {
        if (finished) return;
        closeOutput();
        cleanup();
      },
      cancelOnError: false,
    );
  });

  static Future<T> _awaitTransportResponse<T>(
    Future<T> request, {
    required Future<void> requestSent,
    required RequestOptions options,
    required Future<void>? cancelFuture,
    required rhttp.CancelToken cancelToken,
  }) async {
    final receiveTimeout = options.receiveTimeout;
    final result = Completer<T>();
    Timer? receiveTimer;
    request.then(
      (response) {
        if (!result.isCompleted) result.complete(response);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    cancelFuture?.then((_) {
      if (result.isCompleted) return;
      _cancelRequest(cancelToken);
      result.completeError(
        DioException.requestCancelled(
          requestOptions: options,
          reason: 'Request cancelled',
        ),
      );
    });
    requestSent.then((_) {
      if (result.isCompleted || !_hasTimeout(receiveTimeout)) return;
      receiveTimer = Timer(receiveTimeout!, () {
        if (result.isCompleted) return;
        _cancelRequest(cancelToken);
        result.completeError(
          DioException.receiveTimeout(
            timeout: receiveTimeout,
            requestOptions: options,
          ),
        );
      });
    });
    try {
      return await result.future;
    } finally {
      receiveTimer?.cancel();
    }
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
