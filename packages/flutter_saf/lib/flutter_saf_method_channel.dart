import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_saf_platform_interface.dart';


/// An implementation of [FlutterSafPlatform] that uses method channels.
class MethodChannelFlutterSaf extends FlutterSafPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_saf');

  @override
  Future<List<String>?> pick() {
    return methodChannel.invokeListMethod<String>("pick");
  }
}
