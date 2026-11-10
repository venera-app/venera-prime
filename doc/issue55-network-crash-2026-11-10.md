# #55 网络回调取消导致原生闪退

## 证据与复现

反馈：https://github.com/venera-app/venera-prime/issues/55#issuecomment-6758575218。
报告设备为华为 Pura 70 / 鸿蒙 4.2，现象是不挂 VPN 启动后闪退。
日志确认进程为 Prime，SIGABRT，栈包含 librhttp.so 的
`frb_dart_fn_deliver_output`，报错为：

```
called `Result::unwrap()` on an `Err` value:
Dart2RustMessageSse { vec: [0, 0, 0, 0, 0, 0, 0, 0], data_len: 1 }
```

在 Linux 上使用修改前的实际 rhttp 原生库、回环 HTTP 服务复现：Rust
收到响应后调用 Dart 的 onResponse，故意延迟该回调的完成；取消请求并
等到取消回调到达后，允许原回调返回。Flutter 测试子进程稳定收到
SIGABRT，产生与报告完全相同的 message 内容，源码定位到
flutter_rust_bridge 2.11.1 `dart_fn/handler.rs` 中的
`completer.send(message).unwrap()`。

rhttp 用 tokio::select! 等待取消与请求执行。取消会丢弃请求分支正在等待
的回调 receiver，但 Dart 的回调仍可能稍后返回。向已关闭的 receiver
发送结果是可预期的取消结果；强制 unwrap 却触发 panic。rhttp 在 dev
和 release 都使用 panic=abort，外围 catch_unwind 不能阻止进程退出。
这说明网络超时/取消存在确定的崩溃路径；日志本身仍不能指出用户设备上
具体哪个 URL 或哪一次请求触发它。没有把此前的 SAF 问题当作这一堆栈的根因。

## 修复与相似路径检查

- Dart 回调结果接收端已取消时，安全丢弃结果，不 panic、不打印回调载荷；
  从注册表取出 sender 后先释放锁，再投递结果。正常回调继续投递，未知/
  重复 call ID 保持忽略。响应、错误及 DNS 使用同一个回调分发器。
- 将 rhttp 0.15.1 及原生 flutter_rust_bridge 2.11.1 必要源码固定在仓库，
  记录来源、校验值与 MIT 许可证。Cargo 使用插件内部 vendor 路径补丁，
  Pub/Cargo lockfile 一并固定。保持 Dart/生成桥接代码的 2.11.1 ABI，
  未修改本机依赖缓存，也未通过切换 panic 策略掩盖问题。
- 无效 HTTP 方法改为请求错误；缺失上传 body stream 改为请求错误；
  默认客户端初始化失败沿 Result 传播；连接错误没有 inner source 时
  使用外层错误详情，避免另一处 unwrap。
- 自定义 Dart DNS resolver 抛错时返回空地址列表，由网络库报告解析失败，
  防止异常穿过“不允许抛错”的生成回调而触发 Rust expect/panic。
- 上传流的通道发送/关闭本来就返回 Result；响应数据 chunk 的 unwrap
  前有 is_err 分支保护。客户端共享读锁当前没有并发写锁入口，未将内部
  生命周期断言机械替换成默认值。FRB 的底层解码/线程上下文断言仍保留。
  本次不是对整个 Rust/Flutter 引擎的所有 panic 做消除，也未验证 Web 专用实现。

## 验证

最终全量 Flutter 测试 **393 通过、2 跳过**（启用真实原生库）；全仓静态
分析无 error/warning，仅保留 about.dart 原有参数排序提示。Android 测试
设备为 HUAWEI TAS-AN00 / Android 12，Release 模式通过上述用例并空闲
60 秒，进程仍存活。诊断包在保存结果后已移除，正式包和原测试包仍在。
最初并行构建诊断 APK 时临时修改包名影响了一个工作流断言，配置恢复后
重新完整执行测试通过；没有修改该断言来绕过检查。

- `test/support/rhttp_callback_cases.dart`：响应/错误回调 × 请求/客户端取消
  × 5 轮，共 20 轮真实 FFI 竞态；每轮之后请求回环服务验证网络仍可用。
  额外覆盖三个非法 HTTP 方法、缺失上传流、自定义 DNS 抛异常，以及
  错误之后继续正常请求。无外部账号、源脚本或第三方服务。
- 原有 `rhttp_transport_timeout_test.dart` 的等待响应超时、接收停滞、
  上传停滞、取消、缓慢持续上传和连接拒绝回归通过。
- 独立 Android ARM64 Release 诊断包使用相同测试代码，手动 ADB 安装，
  包名为 `com.github.wgh136.venera.prime.rhttpprobe`。没有使用自动卸载
  应用的 Flutter test 真机驱动；测试前后核对正式 Prime 安装状态。
- 通过 Flutter 插件软链接路径运行 `cargo tree --locked`，确认解析到
  插件内部的补丁 crate；Android 构建实际重新编译了该依赖。

复现/验证命令（Linux）：

```sh
RUSTFLAGS='--cfg reqwest_unstable' cargo build --locked --release \
  --manifest-path packages/rhttp/rust/Cargo.toml --lib
LD_LIBRARY_PATH="$PWD/packages/rhttp/rust/target/release:$PWD/build/linux/x64/debug/bundle/lib" \
  PRIME_NATIVE_ZIP_TEST=1 flutter test test/rhttp_callback_lifecycle_test.dart \
  test/rhttp_transport_timeout_test.dart
```

原设备未直接验证。本轮不升版本、不提交、不发布、不关闭 issue。
