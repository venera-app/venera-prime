import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
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
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
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
  Future<rhttp.ClientSettings> get settings async {
    var proxy = await getProxy();

    return rhttp.ClientSettings(
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
      dnsSettings: rhttp.DnsSettings.static(overrides: _getOverrides()),
      tlsSettings: rhttp.TlsSettings(
        sni: appdata.settings['sni'] != false,
        verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
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
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    var res = await rhttp.Rhttp.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      settings: await settings,
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
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
