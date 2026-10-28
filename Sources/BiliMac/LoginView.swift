import SwiftUI
import CoreImage.CIFilterBuiltins
import BiliMacCore

struct LoginView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var status = "正在生成二维码…"
    @State private var refresh = UUID()
    @State private var finished = false
    var body: some View {
        VStack(spacing: 22) {
            HStack { Text("欢迎来到 BiliMac").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("关闭登录") }
            Text("使用哔哩哔哩 App 扫码，在手机上确认登录").font(.callout).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius:18).fill(.white).frame(width:230,height:230)
                if let image { Image(nsImage:image).interpolation(.none).resizable().frame(width:200,height:200) }
                else { ProgressView().tint(.gray) }
            }
            Text(status).font(.callout).multilineTextAlignment(.center).frame(minHeight:36)
            Button("刷新二维码") { refresh = UUID() }.buttonStyle(.glass).disabled(finished)
            Text("登录信息仅保存在本机钥匙串。BiliMac 是非官方客户端。")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.padding(30).frame(width:460)
            .task(id:refresh) { await login() }
    }
    private func login() async {
        image = nil; status = "正在生成二维码…"; finished = false
        if store.isDemo { status = "演示模式不请求登录。请正常启动应用后扫码。"; return }
        do {
            let qr = try await store.client.qrCode(); try Task.checkCancellation()
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(qr.url.utf8)
            guard let source = filter.outputImage, let cg = CIContext().createCGImage(source.transformed(by:CGAffineTransform(scaleX:8,y:8)),from:source.extent.applying(CGAffineTransform(scaleX:8,y:8))) else { throw ClientError.invalidResponse }
            image = NSImage(cgImage:cg,size:NSSize(width:200,height:200)); status = "等待扫码"
            for _ in 0..<90 {
                try await Task.sleep(for:.seconds(2))
                switch try await store.client.pollQR(qr.key) {
                case .waiting: status = "等待扫码"
                case .scanned: status = "扫码成功，请在手机确认"
                case .expired: status = "二维码已过期，请刷新"; return
                case .confirmed(let cookies):
                    try Task.checkCancellation(); finished = true
                    try await store.completeLogin(cookies); return
                }
            }
            status = "二维码已过期，请刷新"
        } catch is CancellationError { }
        catch { status = error.localizedDescription }
    }
}
