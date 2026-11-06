# 自定义目录、EPUB 与音量翻页回归检查

## 输入与范围

关联 #43，以及 2026-11-06 提供的三份 `.venera` 备份。仅本地检查备份结构、设置及数据库完整性，未导入账号、cookie 或 WebDAV 配置，未执行备份中的漫画源脚本。

三份 ZIP CRC、各自五个 SQLite 数据库 integrity_check 均通过。备份不含本地漫画文件及 local.db，不能直接重建提出者从 2.6.0 持续覆盖安装的完整环境。

## 修正

- SAF 目录列表中的文件／子目录句柄应使用 document URI，原实现误用了 children URI。修正后读取文件及获取长度可使用扫描得到的句柄。
- 通用目录大小统计使用列表返回的 File 类型，不再用原生文件系统类型查询判断 `android://` 路径。
- EPUB 跨 isolate 只传路径，在工作 isolate 内重新打开文件，避免共享带原生句柄与 finalizer 的 SAF File 对象。
- JNI 调用以作用域管理线程附着：仅解除本次调用自行附着的线程，同时保留 local frame 清理。原线程退出清理函数没有注册线程私有值，不能依赖它解除附着。
- SAF 扫描返回的原生句柄数组先复制为 Dart List，再立即释放原生数组；同步和异步递归扫描不再依赖这些数组的 GC finalizer 回收。下方记录了 Release 压力对照结果，尚不能据此确认用户闪退根因。
- 翻页动画期间，以待到达页计算下一次按键的目标，支持快速连续按键及反向操作。

## 验证

设备：HUAWEI TAS-AN00（Android 12），独立 integrationtest 包，使用自行生成的测试文件。

- 修复前真机：SAF 列表文件大小应为 8192，实际为 0，测试失败。
- 修复前自动化：连续两次音量下一页回调应到第 3 页，实际到第 2 页。
- 修复后全量 Flutter 测试：392 通过、2 跳过（外部环境配置相关）；开启 PRIME_NATIVE_ZIP_TEST 并使用已构建 Linux native libraries。
- 修复后额外验证快速反向翻页通过；静态分析通过；C++ SAF 短读、零长度管道、EOF 与读取错误测试通过。
- 真机 SAF：同步读取、同步/异步递归扫描、非零大小统计通过。
- 真机实际 EPUB 导出入口：本地记录入库、关闭并重新打开 LocalManager、重新查询漫画、导出 EPUB；封面与页图解压后与输入的 8192 字节逐字节一致。
- 真机导出后空闲 75 秒再读文件通过；独立 JNI worker 空闲 80 秒测试通过。

原始闪退在修复前的 80 秒空闲测试中也未复现。JNI 修改属于针对明确生命周期隐患的修正，不宣称已确认用户闪退根因或覆盖荣耀设备。数据库重新加载不等同于完整的跨版本覆盖安装；原设备仍需复查并提供系统 crash/logcat。

## 真机测试运行注意

Flutter 集成测试在构建前读取缓存 APK 的包名，结束后会卸载该包。必须先构建本次独立测试 APK，并确认其包名，再启动测试；Gradle 中已有独立 applicationId 仍不足以防止旧缓存包名被使用。操作要求已写入 AGENTS.md。

例如先执行 `flutter build apk --debug -t integration_test/saf_storage_test.dart --dart-define=PRIME_SAF_DEVICE_TEST=true`，用 Android SDK 的 `aapt dump badging build/app/outputs/flutter-apk/app-debug.apk` 核对 package name，再执行 `flutter test integration_test/saf_storage_test.dart -d <设备序列号> --dart-define=PRIME_SAF_DEVICE_TEST=true`。测试期间不得用正式构建覆盖同一 APK 缓存。

SAF 测试需 `--dart-define=PRIME_SAF_DEVICE_TEST=true`，在系统选择器中授权专用测试目录，默认跳过以免无人值守测试停在授权页。

本次发现测试期间设备上的正式 Prime 包不再安装，疑为旧缓存包名导致的测试清理。原版 `com.github.wgh136.venera` 仍在；无法确认或恢复正式 Prime 的原私有数据。未使用他人的备份覆盖设备数据。

## 本地测试包

已构建 ARM64 release 模式修复测试包，使用本地测试签名、独立包名 `com.github.wgh136.venera.prime.integrationtest`，桌面名称 `Venera Prime Test`；不作为正式发布，也不能用它覆盖正式包。已安装至 ADB 设备。GitHub 已发布的正式 v2.7.2 APK 也已重新安装，两个包同时存在；正式 Prime 原私有数据无法确认恢复。版本号及既有 Release 未改动。

## 追加：扩大闪退复现范围

使用独立包手动 `adb install -r`，未再次运行会自动卸载应用的 Flutter 集成测试驱动。测试前后核对正式包仍在。旧版 SAF 通过临时替换原生层构建诊断 APK；构建后已恢复工作区修复代码。诊断入口为 `integration_test/saf_crash_probe.dart`，默认禁止启动，需显式传入 `PRIME_SAF_CRASH_PROBE=true`。

- **旧版原生层线程回收**：32 个并发 isolate 分别进入 JNI 并阻塞 500 ms，迫使多条 OS 工作线程参与；结束后空闲 180 秒，仍存活，未出现对应包的 native crash。比原先立即返回的 12 个任务更接近线程回收条件。
- **旧版 Debug SAF 压力**：12 个章节目录，每章 32 个文件，每个文件 8192 字节；4 个 isolate 并发递归扫描、大小查询、重开文件读取，并进行临时内存分配；8 轮共 12,288 次文件检查，再空闲 180 秒，未崩溃。大小查询持续错误，路径重开读取可用。
- **去敏备份升级**：在另一个独立包中，用用户较早的 WebDAV 备份副本保留设置及四个非 Cookie 数据库，移除 WebDAV、账号及源配置文件，不运行备份中的源脚本，关闭自动更新／追更；先安装实际 v2.6.3 源码构建的测试包，随后 `install -r` 覆盖到实际 v2.7.2 源码测试包。应用保留 2,158 条历史记录，首页、历史列表可操作，升级后心跳持续 6 分钟，仍存活。系统退出记录中只有覆盖安装引起的 USER REQUESTED，没有该包的 crash。
- **旧版 Release/AOT SAF 压力**：同样 384 个文件、4 个并发 worker，共 4 轮后空闲 180 秒，未崩溃。前三轮每个 worker 返回 384 个文件且全部大小错误；第四轮每个 worker 仅返回 64 个文件。此时用 ADB 直接检查磁盘仍有 384 个文件，因此是扫描遗漏，不能解释成文件已删除。不能仅凭一次压力实验确定遗漏的完整原因。

这些结果不能证明用户没有遇到闪退。当前设备为华为 TAS-AN00 / Android 12，报告设备为荣耀 90 GT / MagicOS 7.2；备份不含用户本地漫画文件和 local.db，未还原真实源脚本、账号和完整旧缓存，也未复刻从 2.6.0 一路升级的全过程。JNI 附着清理仍是合理防护，但上述旧版对照没有复现崩溃，不能把它写成已确认的闪退根因。进一步定位需要原设备系统 crash/logcat 或 tombstone，而不仅是应用内导出错误日志。

### 2026-11-07：目录数组生命周期对照

初步修复版（已修正 document URI、JNI 作用域，但未改 Dart 句柄数组）Release 压测也出现扫描遗漏：前两轮各 worker 为 384 文件 / 0 错误，后两轮为 64 文件 / 0 错误。这里的“0 错误”仅代表枚举出的文件没有长度／读取错误，不代表枚举完整。

保留相同 Kotlin/C++ 修复，比较 Dart 侧句柄数组释放方式；均为 ARM64 Release/AOT、12 章 × 32 文件 × 8192 字节、4 个并发 isolate，并施加临时分配压力：

| 句柄数组处理 | 轮次 | 每个 worker 的扫描结果 | 空闲观察 | 崩溃 |
| --- | --- | --- | --- | --- |
| 原 finalizer 方式，初次修复版 | 4 | 前 2 轮 384，后 2 轮 64 | 90 秒 | 未复现 |
| 立即复制为 Dart List 后释放 | 4 | 全部 384 / 0 错误 | 90 秒 | 未复现 |
| 立即复制为 Dart List 后释放 | 8 | 全部 384 / 0 错误 | 90 秒 | 未复现 |
| 只撤回数组复制的对照包 | 8 | 前 7 轮 384，第 8 轮四个 worker 均为 64；读取错误均为 0 | 30 秒 | 未复现 |

两次复制数组测试共完成 18,432 次文件检查。撤回后扫描遗漏再次出现，支持保留显式复制／释放改动；但不能仅凭这组测试断言 Dart VM 的具体回收机制，也不能把扫描遗漏等同于用户报告的进程闪退。此前旧版出现遗漏时已通过 ADB 确认磁盘仍有 384 个文件；最后一组对照结束后探针已自动删除自己的测试目录，因此未再取得该组清理前的独立磁盘计数。

检查 issue #43 的 log.txt，只有网络错误与 `Failed to read SAF document` 导出异常，没有原生崩溃堆栈。系统 crash buffer 中其他包的崩溃未计入 Venera；诊断包退出记录没有 crash，覆盖安装引起的 USER REQUESTED 不计为闪退。完整应用覆盖升级测试保留的进程在本轮排查结束前仍存活。

本轮 `flutter analyze` 无 error/warning，有一个 HEAD 已存在的 `about.dart:59` 排序提示；`git diff --check` 通过。此前 392 通过、2 跳过的全量测试发生在本次数组改动之前；本次数组改动的主要验证是上述 Android Release 真机对照。

更新独立 `Venera Prime Test` Release 测试 APK，保留正式 Prime；临时 crashprobe/aotprobe 包在日志保存后移除。没有升正式版本、提交、发布或关闭 issue。

原设备复现时，需同时保留 `adb logcat -b crash -v threadtime` 和 `adb shell dumpsys activity exit-info com.github.wgh136.venera.prime` 的相关进程记录，以区分 native crash、ANR、系统杀进程与应用主动退出。分享日志前应剔除其他应用和账号信息。
