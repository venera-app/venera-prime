# rhttp local dependency

Source: pub.dev `rhttp` 0.15.1 (https://pub.dev/packages/rhttp/versions/0.15.1).
Upstream: https://codeberg.org/Tienisto/rhttp. License: MIT (LICENSE).
Published archive SHA-256: `b111638045b730f825a85cb045017b5bd3dfb47b38e98eb293b0519ee6050f2e`.

Runtime sources, generated Dart/Rust bridge, platform build integration and upstream
cargokit are retained. Example apps and upstream tests are not vendored. The app's
real native-library regressions are in `test/rhttp_callback_lifecycle_test.dart`
and `test/rhttp_transport_timeout_test.dart`.

Local changes for issue #55:

- Cargo patches flutter_rust_bridge 2.11.1 to the plugin-internal
  `rust/vendor/flutter_rust_bridge` directory (safe through Flutter plugin symlinks). Both the path and Cargo.lock are tracked;
  all platform builds compile the patched source. Pub/Cargo caches are not edited.
- Return request errors instead of panicking on invalid HTTP methods, missing
  request-body streams, default-client construction failure and connection errors
  without an inner source.
- Convert a throwing custom Dart DNS resolver to an empty DNS result so the
  infallible generated callback does not panic across FFI.

Keep generated bridge files and the Dart bridge version compatible with 2.11.1.
Do not replace these fixes by changing panic=abort to unwind: catch_unwind is not
an error-handling strategy for normal request cancellation.
