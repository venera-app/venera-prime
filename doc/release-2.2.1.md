# Venera Prime 2.2.1

## 修复

- 修复运行时版本号仍停留在 2.1.0，导致 2.2.0 安装后仍提示有可用更新的问题。

## 构建检查

- GitHub Actions 在 push、pull request 和 release 时校验 `pubspec.yaml` 的版本与 `lib/foundation/app.dart` 的运行时版本一致。
- 发布 event 还会校验 Release tag 与 `pubspec.yaml` 版本一致；检查失败时不会开始各平台构建。

## 验证

- 版本一致性检查通过。
- Release 工作流自动化测试通过。
