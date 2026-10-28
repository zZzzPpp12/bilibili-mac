# BiliMac 架构

## 模块

```text
BiliMac（SwiftUI / AppKit）
  AppStore ── BilibiliClient（actor，BiliMacCore）
     │              ├─ WBI / URLSession / 业务响应验证
     │              └─ 官方 API / 二维码 / 弹幕 Protobuf
     ├─ HistoryRepository / CredentialVault（独立存储空间）
     └─ PlayerController（长期存活的 AVPlayer owner）
            └─ BiliKitCore DASHToHLSBridge
                   ├─ 读取并解析 SIDX
                   ├─ 构造音频/视频 HLS byte-range 播放列表
                   └─ 本机 HTTP 服务 → CDN Range 请求
```

`BiliMacCore` 不依赖 SwiftUI。API 返回应用自己的 Video / VideoDetail / WatchRecord，媒体地址映射为 Vendor 的 MediaRepresentation。AppStore 负责导航、列表任务与当前账号；PlayerController 负责播放项、桥接会话、进度和弹幕加载。

## 生命周期

- 列表请求使用 Task 取消与 feedGeneration，快速换页后的旧响应不更新当前界面。
- BilibiliClient 使用独立的会话 generation，退出或换号后丢弃旧响应。
- 播放会话使用独立 generation；新视频、切分 P、切画质均取消旧异步任务。
- 页面展示 `showPlayer` 与播放会话 `isOpen` 分离；迷你播放器复用同一个 AVPlayer。
- AVPlayerItem 被替换前先解除旧观察、暂停、停止回环服务器；关闭时保存进度并释放会话。
- 切画质保存 position 与 playing intent；连续切换沿用尚未完成的恢复意图。

## 媒体范围

0.1 使用桥接层的标准流式 Range 读取、上游候选源验证和错误传播，没有接入参考项目额外的自适应并发、持续预读到片尾、下载或自动码率策略。常见 SDR H.264/AAC 是基本验证目标；HEVC 仅按接口实际表示提供，HDR/杜比不作完整兼容承诺。

桥接只绑定回环地址并验证随机会话路径/Host。媒体请求仅携带 User-Agent 和 Referer，不携带账号 Cookie。API URL 固定为对应官方主机；凭据请求拒绝跨主机重定向。

## 弹幕

数据层解析 Protobuf varint 与长度字段，忽略未知可跳过字段，拒绝截断/溢出数据；不执行高级弹幕脚本。播放器按当前六分钟段加载当前及下一段，保留附近数据。原生 NSView 根据 AVPlayer 时间排轨、计算滚动位置，最多呈现 100 条可见文字；暂停/空档停止显示刷新，界面时间更新负责恢复。

首版排轨和图层准备仍在主线程进行，中高密度弹幕性能是后续优化项，未将桌面刷新率目标当成已经完成的实测承诺。

## 存储

- Keychain service：`dev.zzpp.BiliMac.session`，只保存本应用主动扫码取得的必要 Cookie。
- UserDefaults suite：`dev.zzpp.BiliMac`。
- 历史：`Application Support/BiliMac/history.json`，最多 200 个视频，保留各 CID 位置。
- 演示模式不读取 Keychain，使用独立演示历史文件，明确显示演示标识。
- CDN 签名 URL 不落盘，不写入历史和日志。

## 第三方边界

只引入兼容 macOS 26 SDK 的 BiliKitCore 桥接子集。没有包含 AVPlayerEngine、响度处理 tap 和参考应用 UI。来源提交与抽取改动见 THIRD_PARTY.md。

## 后续演进

优先增加取消/会话隔离回归、用户主动扫码验收、真机画质/分 P/小窗回归，再增加图片解码缓存和后台弹幕排轨。P1 才接入收藏、评论及离线下载；这些写入路径需要单独的防重复提交与结果确认策略。iOS 在核心边界稳定后采用独立原生 UI。
