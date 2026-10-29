# Third-party notices

BiliMac's application UI, business API adapter, credential storage, history and playback owner are implemented for this repository.

## BiliKit-Mac / Bilibili NEXT playback bridge

- Original author: shiinayane; MIT License, retained in `Vendor/BiliKitCore/LICENSE`.
- Original project: https://github.com/shiinayane/BiliKit-Mac
- Original revision identified by Bilibili NEXT: `0d6cb46db6bfc3b54020f3cb20b46c92d5395c4a`.
- Immediate source: https://github.com/wzk112/Bilibili-NEXT at `3b7582c42c0695e5f8da1255d506f3802e2ed417`.
- Bilibili NEXT's MIT notice is retained in `Vendor/BiliKitCore/BILIBILI-NEXT-LICENSE`.

### Status since 0.6.0

The application and tests now build against the repository's `BiliMacMedia` target. The package has no BiliKitCore dependency and no automatic fallback to its bridge. Media types, URL policy, bounded HTTP Range reader, SIDX parsing, virtual-fragment HLS presentation and local transport are implemented in this repository. This is a specification-driven rewrite; its author has inspected the prior implementation, so it is not represented as a certified clean-room process.

`Vendor/BiliKitCore` remains in the source repository as historical reference, with its original notices. It is not built or linked into the 0.6.0 application. Historical MIT notices remain bundled during this preview transition; the presence of those notices does not mean the legacy bridge is being executed.

The previous upstream blue-video/silent-audio fixtures have been removed from the current test resource directory. New moving-color and audible-beep fixtures are generated from this repository's own raw pixels/PCM by `Scripts/generate-media-fixtures.py`. FFmpeg is an external development tool used to encode those files; it is not bundled or linked into the application. Generation parameters and file hashes are documented in `Tests/BiliMacTests/Fixtures/README.md`.

## Protocol references

The WBI signing table and public signature test vector describe the Bilibili protocol. API paths and field layouts are informed by the reference repository and community API documentation. No official SDK endorsement is implied. Bilibili names, marks, videos and account content belong to their respective owners.
