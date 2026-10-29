# BiliMac 架构

## 模块

```text
BiliMac（SwiftUI / AppKit）
  AppStore ── BilibiliClient（actor，BiliMacCore）
     │              ├─ WBI / URLSession / 业务响应验证
     │              └─ 官方 API / 二维码 / 弹幕 Protobuf
     ├─ SearchModel → SearchServing（视频/用户分类、独立结果与分页）
     ├─ UserProfileStore → UserProfileModel → UserServing（资料/投稿/关注）
     ├─ HistoryRepository / CredentialVault（独立存储空间）
     ├─ LibraryModel → LibraryServing（收藏/稍后再看）
     ├─ FavoriteEditorModel（勾选草稿、差集、写入确认）
     ├─ CommentsModel → CommentServing（游标/楼中楼）
     ├─ CommentActionsStore → CommentActionsModel → CommentWriting
     │                         （每视频/目标草稿、回执、点赞、本人删除）
     ├─ InteractionStore → VideoActionsModel → VideoInteractionServing
     │                    （会话/稿件状态、确认草稿、部分回执）
     └─ PlayerController（长期存活的 AVPlayer owner）
            └─ PlaybackPreparing → NativePlaybackBridge（BiliMacMedia）
                   ├─ 自有 MediaTrack / ByteSpan、SIDX v0/v1
                   ├─ 内存 HLS 与虚拟分片，不转码
                   └─ 会话回环服务 → 有界 Range 读取 → 官方 CDN
```

`BiliMacCore` 不依赖 SwiftUI。API 返回应用自己的 Video / VideoDetail / WatchRecord，媒体地址映射为本项目 BiliMacMedia 的 MediaTrack。AppStore 负责导航、列表任务与当前账号；PlayerController 负责播放项、桥接会话、进度和弹幕加载。

## 生命周期

- 列表请求使用 Task 取消与 feedGeneration，快速换页后的旧响应不更新当前界面。
- BilibiliClient 使用独立的会话 generation，退出或换号后丢弃旧响应。
- 播放会话使用独立 generation；新视频、切分 P、切画质均取消旧异步任务。
- 页面展示 `showPlayer` 与播放会话 `isOpen` 分离；迷你播放器复用同一个 AVPlayer。
- AVPlayerItem 被替换前先解除旧观察、暂停、停止回环服务器；关闭时保存进度并释放会话。
- 切画质保存 position 与 playing intent；连续切换沿用尚未完成的恢复意图。

## 媒体范围

0.6 将默认播放路径切换到自有 BiliMacMedia，仅提供 H.264/AAC 普通点播；API 映射过滤尚未验证的 HEVC 选项，不展示无法由当前桥接处理的画质。首版采用有界分片缓冲而非整片下载：单次最多 16 MiB，媒体交付并发为 2，并在下游发送完成后释放配额。尚未实现跨会话缓存、自动 CDN 续接、过期 URL 刷新与自动码率。

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

0.6 的 Package.swift 无外部包依赖，应用和测试只依赖本项目 BiliMacMedia。Vendor/BiliKitCore 作为历史参考保留在仓库并附原许可，但不构建、不链接，也无运行时回退。预览过渡期仍随包附带历史许可。新合成媒体由本项目像素/PCM 生成；FFmpeg 只用于开发编码，不是运行依赖。来源说明见 THIRD_PARTY.md。

## 后续演进

0.2 已接入个人资料库与只读评论。`LibraryServing` / `CommentServing` 使用可发送的强类型值，允许测试注入可控延迟，不依赖真实凭据。收藏夹列表、夹内分页、稍后再看、评论主列表与楼中楼各自保留请求身份；账号变化清空私有内存快照。普通主评论分页不会作废正在加载的楼中楼，成功刷新则清空旧楼中楼。

认证 POST 允许列表覆盖四条资料库端点、三条视频互动端点、三条评论写入端点及一条关注端点，校验 mid 与当前 Cookie 一致并加入 CSRF；表单按 UTF-8 百分号编码，POST 不跟随重定向。状态模型阻止重复写入，传输/回执不确定则进入必须先读取核对的状态。收藏多选草稿不直接写服务器；新建收藏夹是单独的即时写入。账号 Cookie 不进入评论视图、截图夹具或测试日志。

0.3 的视频互动通过 `VideoInteractionServing` 隔离网络。一次状态读取在同一认证 generation 内组合稿件类型/作者、relation 和 nav 余额；视频互动在提交前向官方 finger/spi 获取必要浏览标识，只驻留当前会话内存。点赞使用明确的 like/unlike，投币选择 1–2 枚，三连只调用单次服务端端点，不在客户端拆成多次花费。

`InteractionStore` 在当前账号内按 aid 保留状态模型，避免暂离页面后丢失未知写入结果；退出/换号使全部模型失效。投币确认绑定稿件和状态快照，最终提交前重新读取；状态变化使旧确认失效。三连回执按 like/coin/fav 与实际新增数量合并；部分成功要求刷新，已投币但本次 coin=false 时不再扣减余额。用户确认前不会产生互动 POST；测试会话的所有写操作都在 URLProtocol 内截获。

0.4 新增独立 `CommentWriting` 协议，读取列表与写入状态分离。`CommentActionsStore` 按账号/aid 保存状态，每个模型按 parent 保存草稿；切视频或换排序不会丢掉未知提交结果。发布回执只存编号与本次正文，不进入 `CommentsModel.items` 或总数；公开可见性不由写入回执推断。点赞成功后通过 comment ID 的共享覆盖值同步主列表/楼中楼预览/已展开回复；成功手动刷新清除此覆盖值，失败不清除。本人评论删除经确认后以 ID 隐藏，不从未知列表缺失推断删除成功。

评论写入结果未知时，刷新仅 GET，仍保持限制；列表缺失可能来自分页或平台处理，不能作为重发依据。只有用户明确已到官方页面核对，才能手动解除限制，解除本身不发网络请求。凭据请求及 UI 模型均以各自的会话身份过滤迟到结果。

后续优先用户主动扫码验收、真机画质/分 P/小窗回归，再增加后台弹幕排轨和评论图片预览。离线下载和 iOS 继续保留独立里程碑。

## 0.5 用户链路

`Users.swift` 将用户搜索、公开资料卡、WBI 投稿列表与关注写入映射为 `BiliUser` / `UserProfile` / `UserSearchPage` / `UserVideoPage`。缺失计数与关注关系为 optional，不从空值推断零或未关注；投稿兼容 `length` 时长字段并补齐当前主页作者 UID。`Video.authorID` 和 `Comment.avatar` 为旧调用提供默认值；旧历史缺少 authorID 仍可解码。

`SearchModel` 按视频/用户保存独立页码与结果，请求代次在切分类、新词、刷新和关闭时失效。`UserProfileStore` 按当前账号/UID 保留模型；资料和投稿各自拥有请求标识、错误和刷新。排序、新账号、失效模型的旧响应被丢弃。关注请求只有一个在途操作，成功后切换关系，错误要求重新读取已知关系，不自动 POST。账号会话在网络层和视图层均有独立代次保护。

`AppStore.profilePath` 保存主页来源和必要的播放器返回记录。正常浏览主页不替换 AVPlayer，迷你播放器继续可用；主页内打开另一视频后，返回上层作者来源可恢复原视频/CID/位置/暂停意图。用户明确关闭播放项后不会恢复。搜索结果模型不因展示主页而重置。

用户搜索和投稿先向官方 finger/spi 获取浏览标识，再使用 nav 返回的 WBI key；不生成伪造标识，标识仅在当前会话内存。投稿采用对应官方空间 Referer。成功业务码里的 v_voucher / need_captcha 也视为验证错误，提供官方链接和登录/重试。头像复用封面共享下载/成功缓存，使用 160×160 缩略图并保留原图回退；图片不携带账号 Cookie。

## 0.6 自有媒体模块与首阶段边界

MediaTrack / ByteSpan 是独立类型；NativePlaybackBridge 通过 MediaReading 注入读取器。初次准备对每轨最多验证 3 个候选来源，成功后固定该来源。索引与 init 各最多 2 MiB；SIDX 支持直接引用与 v0/v1，拒绝间接索引、溢出、截断和文件越界。初始化当前只做顶层 ftyp/moov 与大小检查，尚未完成所有 sample entry / tfdt / 寻址兼容性验证。

音视频各自生成不可变 VOD 目录，按独立时间刻度记录段长；不发布未经证明的 I-frame/独立分段标签。每个虚拟分片映射到原文件有界范围，局部 Range 平移回上游，Content-Range 对下游则相对虚拟文件。头部、实际字节数、完整长度与媒体类型不一致时不交付正文。响应失败映射为 502 并保留脱敏原因，应用优先展示该原因；没有后台自动重发。

LocalMediaService 使用 Network.framework，仅监听 127.0.0.1，随机会话路径与精确 Host；限制头部 16 KiB、头部等待 5 秒、总连接 12、连接时限 35 秒。关闭会话取消其连接、下载和等待配额；两条媒体交付通道持有配额到发送完成，最多约 32 MiB 分片数据驻留（另有数据拷贝、索引及系统播放器开销，不能当作进程 RSS 上限）。HTTPMediaReader 的 URLSession 不使用 Cookie/凭据/缓存，只允许 User-Agent 与 Referer，重定向不跟随；16 MiB 是每次读取硬上限。

PlayerController 注入 PlaybackPreparing，继续复用同一个 AVPlayer。分 P、画质和普通页面切换保留已有播放意图/进度机制。自研桥失败直接提示，不调用旧实现。回环交付是当前 macOS 开发版取舍，并不满足苹果关于避免本地服务器的交付建议；AirPlay、上架、公证和跨平台兼容仍需独立评估。

## 0.6.1 播放画面与评论区小窗

PlayerSurface 使用限定在画面区域的 AppKit 单击手势切换播放意图，原生控制条、滑块和菜单保持自己的事件处理。AVKit 内部子视图会消费滚轮；仅在当前窗口、当前可见画面区域使用本地滚轮事件监视器转交父级滚动容器，不监听键盘或应用外事件。离开窗口、SwiftUI 拆卸或释放时移除监视器。

PlayerPage 在固定尺寸的视频占位上监听滚动可见性，低于 20% 时切换为内容区右下角浮动展示；滚回或点击“回到视频”恢复内嵌展示。ScrollPlaybackPresentation 仅管理可见性与本次收起状态，AVPlayer、当前项和媒体会话继续由 PlayerController 持有。位置切换不调用 prepare/open，不重建音视频资源。PlayerController 延迟创建并持有唯一 PlayerSurface，展示槽 PlayerContainer 通过所有权令牌迁移该视图；旧槽延迟拆卸不能解绑新槽，避免暂停时重建视频图层导致黑屏。关闭自动小窗调用 pause，连同尚在加载中的播放意图一起暂停；同一轮评论浏览不自动弹回，视频重新可见后解除收起状态。

自动小窗属于 PlayerPage；离页后仍由 RootView 使用原 MiniPlayer，因此不会叠加两个小窗。列表小窗的关闭仍调用 stop，与评论区的暂停收起保持独立语义。
