# BiliMac

为 macOS 打造的原生哔哩哔哩客户端，使用 SwiftUI、AVPlayer 和本机 DASH/HLS 桥接。

当前为 **0.1.1 开发预览**。修复 0.1.0 打包应用因设置域初始化失败而启动崩溃的问题。从完整 PRD 开始，先实现可浏览、可搜索、可观看的桌面闭环。与哔哩哔哩官方无关联。

## 文档

- [完整 PRD](docs/PRD.md)：用户场景、版本范围、功能细节、验收、安全与发布。
- [架构](docs/ARCHITECTURE.md)：模块与媒体链路。
- [实现与验证状态](docs/IMPLEMENTATION.md)：实际进度和已知限制。
- [第三方来源与许可](THIRD_PARTY.md)。

## 首版功能

- 原生导航、推荐/热门、关键词搜索与 BV 号/视频链接输入。
- 官方网页二维码登录、Keychain 会话保存和账号检查/退出。
- AVPlayer 播放、分 P、实际可用画质、倍速、系统进度/音量控制。
- 普通弹幕、开关与透明度；本机历史、续播、迷你播放器。
- 系统/浅色/深色外观与原生设置窗口。

收藏、评论、投币、下载、高级弹幕与 iOS 是后续里程碑，首版界面不会提供未接通的功能入口。内容和画质取决于官方接口、账号权限和本机解码支持。

## 运行

要求 macOS 26+、Xcode 26+、Swift 6.2+。本项目只编译兼容该 SDK 的播放桥接子集。全部依赖已随源码提供。

```sh
git clone https://github.com/zZzzPpp12/bilibili-mac.git
cd bilibili-mac
bash Scripts/test.sh
bash Scripts/build-app.sh
open .build/BiliMac.app
```

构建脚本会执行打包后的 `BiliMac.app/Contents/MacOS/BiliMac --check-startup`，验证真实 Bundle ID 下的应用/设置初始化，不读取账号、不联网，也不创建窗口。真实窗口启动仍单独验收。

也可以在 Xcode 中打开 `Package.swift`，运行 BiliMac target。

推送 `main` 后，GitHub Actions 会在 macOS 26 上执行默认测试、构建并保存临时签名的开发应用 ZIP。真实接口测试默认关闭，避免 CI 依赖 B 站服务状态。

离线 UI 演示：

```sh
open .build/BiliMac.app --args --demo
```

演示模式明确显示“演示数据”，不会读取钥匙串、登录或加载线上媒体，不能作为真实接口/播放成功证据。

可选的只读联网检查（不读取凭据、不执行互动）：

```sh
BILIMAC_LIVE_TEST=1 BILIMAC_LIVE_PLAYBACK=1 bash Scripts/test.sh --filter LiveTests
```

## 数据与分发

本机历史在 `~/Library/Application Support/BiliMac/history.json`；偏好使用独立的 `dev.zzpp.BiliMac` suite，凭据使用独立 Keychain service。媒体签名地址只保留在内存。不会读取参考客户端或浏览器的凭据。

构建脚本生成 `.build/BiliMac.app` 并临时签名。尚未提供 Developer ID 公证、自动更新或商店分发。不要向仓库提交凭据、媒体、个人诊断或签名证书。

应用代码与文档为 MIT。复用播放组件与测试材料保留各自 MIT 声明。
