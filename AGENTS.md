# 项目约定

准备版本、编写 Release 说明或执行发布时，先阅读并遵循 [发布规范](doc/release-policy.md)。用户明确指定的版本和发布范围优先；不得擅自升版、关闭 issue 或更改既有 Release。

历史待确认问题只列当前仍开放且需要复查的 issue；已关闭的 issue 不得再列入，不得以缺少明确验证反馈等理由例外保留。发布前须重新核对状态，禁止照抄历史名单。

真机集成测试必须先预构建独立测试包，并用 `aapt dump badging` 核实缓存的 `build/app/outputs/flutter-apk/app-debug.apk` 包名为 `com.github.wgh136.venera.prime.integrationtest`，再执行 `flutter test integration_test/... -d ...`。仅在 Gradle 中设置独立 applicationId 不够：Flutter 可能先读取旧 APK 的正式包名，测试结束后误卸载正式应用。不得在缓存包名未核实的情况下执行；测试前后核对正式包安装状态。
