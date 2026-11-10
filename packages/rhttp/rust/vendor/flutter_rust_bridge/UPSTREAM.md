# flutter_rust_bridge native patch

Source: crates.io `flutter_rust_bridge` 2.11.1.
Published crate checksum: `dde126295b2acc5f0a712e265e91b6fdc0ed38767496483e592ae7134db83725`.
Upstream: https://github.com/fzyzcjy/flutter_rust_bridge/tree/v2.11.1/frb_rust
License: MIT (LICENSE, from the upstream v2.11.1 tag).
The published Cargo.toml is retained to preserve registry dependency resolution.

Issue #55: `dart_fn/handler.rs` must not unwrap the result of sending a Dart
callback result to a dropped oneshot receiver. Cancellation can legitimately drop
the Rust request future before Dart acknowledges onResponse/onError (or DNS).
With rhttp's panic=abort profile this kills the process, even inside catch_unwind.

The patch releases the callback map lock before delivery and ignores a closed
receiver, without logging callback payloads. Duplicate/unknown callback IDs remain
no-ops. This follows the same handling principle now present in upstream master.
The Dart package and generated bindings remain at the existing 2.11.1 ABI.
