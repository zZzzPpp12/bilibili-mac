import Foundation
import Network
import AVFoundation
import Testing
import BiliMacMedia

@Suite(.serialized) struct NativeServiceTests {
    @Test func localServiceRejectsWrongHostUnknownSessionAndBodyRequests() async throws {
        let f = try MediaFixtures()
        let bridge = NativePlaybackBridge(reader:f.reader)
        let asset = try await bridge.prepare(video:f.video,audio:f.audio)
        defer { asset.stop() }
        let authority = "127.0.0.1:\(asset.url.port!)", path = asset.url.path
        for (text,status) in [
            ("GET \(path) HTTP/1.1\r\nHost: external.test\r\n\r\n",403),
            ("GET /unknown/main.m3u8 HTTP/1.1\r\nHost: \(authority)\r\n\r\n",404),
            ("POST \(path) HTTP/1.1\r\nHost: \(authority)\r\n\r\n",405),
            ("GET \(path) HTTP/1.1\r\nHost: \(authority)\r\nContent-Length: 1\r\n\r\nx",400)] {
            let response = try await raw(text,to:asset.url)
            #expect(response.hasPrefix("HTTP/1.1 \(status) "))
        }
    }
    @Test func upstreamFailureReturns502AndASanitizedDiagnosticWithoutRetry() async throws {
        let f = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio)
        defer { asset.stop() }
        let count = await f.reader.reads.count; await f.reader.setFailure()
        let (_,response) = try await MediaFixtures.session().data(from:URL(string:"v/seg/0.m4s",relativeTo:asset.url)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(asset.lastFailure != nil); #expect(asset.lastFailure?.contains("https") == false)
        #expect(await f.reader.reads.count == count+1)
    }
    @Test func closingASessionCancelsItsInFlightFragment() async throws {
        let f = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio)
        defer { asset.stop() }
        let before = await f.reader.reads.count; await f.reader.setDelay(.seconds(5))
        let client = MediaFixtures.session()
        let pending = Task { try await client.data(from:URL(string:"v/seg/0.m4s",relativeTo:asset.url)!) }
        for _ in 0..<100 { if await f.reader.reads.count > before { break }; try await Task.sleep(for:.milliseconds(10)) }
        #expect(await f.reader.reads.count > before)
        asset.stop()
        do { _ = try await pending.value; Issue.record("关闭会话必须中止媒体请求") } catch {}
    }
    @Test func independentlyGeneratedAACDecodesIntoNonSilentPCM() async throws {
        let base64 = try #require(Bundle.module.url(forResource:"bilimac-beeps.mp4",withExtension:"base64",subdirectory:"Fixtures"))
        let data = try #require(Data(base64Encoded:Data(contentsOf:base64),options:.ignoreUnknownCharacters))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bili-audio-\(UUID()).mp4")
        try data.write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        let asset = AVURLAsset(url:file)
        let track = try #require(try await asset.loadTracks(withMediaType:.audio).first)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        try #require(reader.canAdd(output)); reader.add(output); try #require(reader.startReading())
        var energy = 0.0, samples = 0
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var bytes = [UInt8](repeating:0,count:CMBlockBufferGetDataLength(block))
            let count = bytes.count
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:$0.baseAddress!) }
            #expect(status == kCMBlockBufferNoErr)
            for index in stride(from:0,to:count-1,by:2) {
                let value = Double(Int16(bitPattern:UInt16(bytes[index]) | UInt16(bytes[index+1]) << 8))
                energy += value*value; samples += 1
            }
        }
        #expect(reader.status == .completed); #expect(samples >= 48000*7)
        #expect(sqrt(energy/Double(max(1,samples))) > 100)
    }
    private func raw(_ text:String,to url:URL) async throws -> String {
        let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(url.port!))!,using:.tcp)
        connection.start(queue:DispatchQueue(label:"bili.raw-http.test"))
        let deadline = Task { try? await Task.sleep(for:.seconds(3)); if !Task.isCancelled { connection.cancel() } }
        defer { deadline.cancel(); connection.cancel() }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,any Error>) in
            connection.send(content:Data(text.utf8),completion:.contentProcessed { error in if let error { c.resume(throwing:error) } else { c.resume() } })
        }
        let data: Data = try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength:1,maximumLength:2048) { data,_,_,error in
                if let error { c.resume(throwing:error) } else { c.resume(returning:data ?? Data()) }
            }
        }
        return String(decoding:data,as:UTF8.self)
    }
}
