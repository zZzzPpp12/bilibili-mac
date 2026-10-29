import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance",store:AppSettings.defaults) private var appearance = "system"
    @AppStorage("autoPlay",store:AppSettings.defaults) private var autoplay = true
    @AppStorage("rememberPosition",store:AppSettings.defaults) private var remember = true
    @AppStorage("danmakuEnabled",store:AppSettings.defaults) private var danmaku = true
    @AppStorage("danmakuOpacity",store:AppSettings.defaults) private var opacity = 0.8
    @State private var licenses = false
    var body: some View {
        Form {
            Section("外观") { Picker("应用主题",selection:$appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") } }
            Section("播放") { Toggle("打开视频后自动播放",isOn:$autoplay); Toggle("记住上次观看位置",isOn:$remember) }
            Section("弹幕") { Toggle("显示普通弹幕",isOn:$danmaku); Slider(value:$opacity,in:0.2...1) { Text("透明度") } }
            Section("关于 BiliMac") {
                LabeledContent("版本",value:"0.6.1 · 自研播放桥预览")
                Text("一个为 macOS 打造的非官方哔哩哔哩客户端。与哔哩哔哩官方无关联。视频、商标与内容归各自权利人。")
                    .font(.callout).foregroundStyle(.secondary)
                Link("项目与源代码",destination:URL(string:"https://github.com/zZzzPpp12/bilibili-mac")!)
                Text("本项目使用 MIT 许可；播放桥接由 BiliMac 自行实现，目前支持 H.264/AAC 点播。历史参考源码的 MIT 声明保留在仓库与随附许可中。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("阅读开源许可证") { licenses = true }
            }
        }.formStyle(.grouped).frame(width:530,height:530).tint(accent)
            .sheet(isPresented:$licenses) {
                VStack(alignment:.leading,spacing:16) {
                    HStack { Text("开源许可证").font(.title2.bold()); Spacer(); Button("完成") { licenses = false } }
                    ScrollView { Text(licenseText).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                }.padding(24).frame(width:680,height:540)
            }
    }
    private var licenseText: String {
        ["LICENSE","BiliKit-LICENSE","BilibiliNEXT-LICENSE"].map { name in
            let text = Bundle.main.url(forResource:name,withExtension:"txt").flatMap { try? String(contentsOf:$0,encoding:.utf8) }
            return "\(name)\n\n" + (text ?? "运行打包后的 BiliMac.app 查看完整许可，或阅读源码目录的 LICENSE 与 THIRD_PARTY.md。")
        }.joined(separator:"\n\n————————\n\n")
    }
}
