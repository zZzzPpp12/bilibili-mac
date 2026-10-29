# BiliMac 自造媒体测试素材

自 0.6.0 起，当前测试使用本仓库生成的素材，不使用之前来自 Bilibili-NEXT 的蓝色视频/静音 AAC。

- `bilimac-colors.mp4.base64`：8 秒、160×96、24 fps 的自造渐变背景和移动色块，H.264 Baseline，每秒一个关键帧与分片，global SIDX。
- `bilimac-beeps.mp4.base64`：8 秒、48 kHz 单声道，自造 660 Hz 提示音，每秒起始 125 ms 发声，其余为零样本；AAC、约每秒一个分片，global SIDX。
- 原始像素与 PCM 由 `Scripts/generate-media-fixtures.py` 直接生成；没有输入上游媒体、视频平台内容或账号数据。源生成脚本与生成素材按仓库 LICENSE 分发。
- 生成命令：`python3 Scripts/generate-media-fixtures.py`。FFmpeg 仅为开发编码工具，不进入产品运行依赖或应用包；常规 CI 直接使用已提交素材，不要求安装 FFmpeg。

本次生成工具：FFmpeg 8.1.1（不同编码器版本可能生成不同字节，更新时应同时记录摘要并回归）。解码后的 MP4：

| 文件 | 字节数 | SHA-256 |
| --- | --- | --- |
| bilimac-colors.mp4 | 24560 | 7dc7bbf7e3fe336686bc0fb78a553832d1100d61db2abd74df715c00e88f608f |
| bilimac-beeps.mp4 | 23963 | d0975dda202d849b370b0fa444e6f01f2963c081f583381ce246dd5db16ca26e |

SIDX 的数值黄金样例单独手写，避免仅用生成器与解析器互证。系统 AVPlayer 检查真实画面推进、音轨选择、媒体读取和暂停拖动；AVAssetReader 将 AAC 解码为 PCM 并检查非零能量。自动播放测试静音，不以系统扬声器是否出声作为断言。
