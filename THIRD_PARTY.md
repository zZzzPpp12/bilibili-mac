# Third-party notices

BiliMac's application UI, business API adapter, credential storage, history and playback owner are implemented for this repository.

## BiliKit-Mac / Bilibili NEXT playback bridge

- Original author: shiinayane; MIT License, retained in `Vendor/BiliKitCore/LICENSE`.
- Original project: https://github.com/shiinayane/BiliKit-Mac
- Original revision identified by Bilibili NEXT: `0d6cb46db6bfc3b54020f3cb20b46c92d5395c4a`.
- Immediate source: https://github.com/wzk112/Bilibili-NEXT at `3b7582c42c0695e5f8da1255d506f3802e2ed417`.
- Bilibili NEXT's MIT notice is retained in `Vendor/BiliKitCore/BILIBILI-NEXT-LICENSE`.

Included subset: BiliModels, BiliNetworking, BiliApplication, and BiliPlayback's Bridge / MediaIndex directories, including NEXT's BiliGlassBridge adapter. NEXT's media URL normalization, bridge signalling and bounded transport changes are retained as present in the source revision. The reference application's UI and account data are not included.

Local changes: a bridge-only package manifest targeting macOS 26; `SelectedPlaybackAudioTrack` extracted from upstream PlayerTypes and `hlsCharacteristic` extracted from LoudnessAudioTrackMatching. The AVPlayerEngine, loudness tap and other unused playback components are excluded, so macOS 27 SDK audio symbols are not required. The core bridge sources are otherwise retained.

The two base64 MP4 test fixtures come from that same source revision. They are synthetic four-second AVC video and silent AAC audio, not captured user media. See `Tests/BiliMacTests/Fixtures/README.md`.

## Protocol references

The WBI signing table and public signature test vector describe the Bilibili protocol. API paths and field layouts are informed by the reference repository and community API documentation. No official SDK endorsement is implied. Bilibili names, marks, videos and account content belong to their respective owners.
