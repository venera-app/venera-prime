# Venera Prime 2.8.0 发布检查

- 版本：pubspec 2.8.0+280、App.version 2.8.0、Release 标题与 v2.8.0 一致。
- 2026-11-07，Flutter 3.41.4/Linux：`LD_LIBRARY_PATH="$PWD/build/linux/x64/debug/bundle/lib" PRIME_NATIVE_ZIP_TEST=1 flutter test`，最终完整运行 392 通过、2 跳过。首次运行早于发布说明落盘，版本说明检查失败；补齐后完整重跑通过。
- `flutter analyze`：无 error/warning；about.dart:59 原有 sort_child_properties_last 提示 1 条。
- C++ `test/native/saf_file_io_test.cpp`：短读、零长度管道、EOF、读取错误通过。
- 搜索相关 11 项测试通过；本轮功能代码的独立 Android Release 测试包已通过 ADB 安装启动。该测试包构建时仍使用 2.7.2 测试版本号，不冒充 2.8.0 正式包升级验证。
- SAF 与原始闪退复现限制见 `issue43-saf-regression-2026-11-06.md`；不宣称闪退已修复。
- 已读取 #43、#51 及开放 issue 的正文和评论。历史待确认表仅 #34、#45、#49，发布前再次检查均为 OPEN；#34 有早期确认，但后来追加了首页配对回归反馈。已关闭条目不列入。
- 匿名提交与机器人发布按 release-policy.md 执行。调度入口完成且确认机器人 Build ALL 启动后，即删除带个人操作者的调度 run；保留机器人六平台构建结果。删除 run 不抹除 GitHub 审计记录。
- 六平台构建与机器人 Release 任务成功才计发布完成；本地不额外下载或核验线上附件。
