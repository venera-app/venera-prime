import 'dart:async';

import 'package:flutter/foundation.dart';

/// A mixin class that provides a way to ensure the class is initialized.
abstract mixin class Init {
  bool _isInit = false;
  Future<void>? _initializing;

  /// Ensure the class is initialized.
  Future<void> ensureInit() {
    if (_isInit) return Future.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await doInit();
      _isInit = true;
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  @protected
  Future<void> doInit();

  /// Initialize the class.
  Future<void> init() => ensureInit();
}
