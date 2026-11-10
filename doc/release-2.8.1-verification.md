# 2.8.1 发布执行记录（2026-11-11）

- 发布标签 `v2.8.1` 固定在 `6987ccf8e7b471d835af48edb81a026f76e15a24`，版本为 2.8.1+281。作者及提交者均为 Anonymous。
- 发布前全量 Flutter 测试：404 通过、2 跳过，启用原生库回归；静态分析只有既存 about.dart:59 提示。版本及空白检查通过。
- 六平台构建：[Build ALL 42862404220](https://github.com/venera-app/venera-prime/actions/runs/42862404220)。Android、iOS、macOS、Windows、Linux x64、Linux ARM64 均成功。macOS 首次因 hosted runner 容量不足未获分配，由机器人重试后成功。
- 原 run 的 Release 请求指定旧提交，GitHub 返回 403，尽管 job 的 Contents 权限为 write。改为从默认分支调用发布恢复流程，核对来源 run 的机器人身份、标签 SHA 和六个成功任务后复用产物，未移动标签。
- [发布恢复 42870592467](https://github.com/venera-app/venera-prime/actions/runs/42870592467) 的 Validate_Version 和 Release 均成功；六个平台在恢复 run 中不重建，其成功证据取自原 run，不能把 skipped 当作成功。
- [Release v2.8.1](https://github.com/venera-app/venera-prime/releases/tag/v2.8.1) 为正式发布，作者 github-actions[bot]，正文与 doc/release-2.8.1.md 一致。未另行下载附件、比对哈希或检查正式 APK 签名。
- 人工调度入口的四条已完成 run 记录均已删除；实际构建和发布 run 保留用于核对。删除 run 不清除审计记录。
- 恢复流程首次使 AltStore job 因上游构建跳过而未执行；已增加 always() 与成功条件，本次由维护流程运行原 update_alt_store.py 更新，并以 Anonymous 身份提交。
- 现有 macOS runner 标签未修改。GitHub 当前将 macos-15 映射为 ARM64，macos-15-intel 才明确选择 x64；Flutter action 的 architecture: x64 不控制 runner 分配。
