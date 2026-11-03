import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_saf_method_channel.dart';

abstract class FlutterSafPlatform extends PlatformInterface {
  /// Constructs a FlutterSafPlatform.
  FlutterSafPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterSafPlatform _instance = MethodChannelFlutterSaf();

  /// The default instance of [FlutterSafPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterSaf].
  static FlutterSafPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterSafPlatform] when
  /// they register themselves.
  static set instance(FlutterSafPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<List<String>?> pick() {
    throw UnimplementedError('pick() has not been implemented.');
  }
}
