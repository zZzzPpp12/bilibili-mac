import Foundation
import Testing
@testable import BiliMacMedia

@Suite struct NativeMediaTests {
    @Test func byteSpansRejectOverflowAndSupportHTTPRelativeRanges() throws {
        #expect(try ByteSpan.parse("bytes=2-9",size:6) == ByteSpan(offset:2,length:4))
        #expect(try ByteSpan.parse("bytes=-2",size:6) == ByteSpan(offset:4,length:2))
        #expect(try ByteSpan.parse("bytes=2-",size:6) == ByteSpan(offset:2,length:4))
        for text in ["bytes=6-","bytes=4-2","bytes=-0","bytes=+1-2","bytes=1-2,4-5","bytes=","other=1-2"] {
            #expect(throws:(any Error).self) { try ByteSpan.parse(text,size:6) }
        }
        #expect(throws:(any Error).self) { try ByteSpan(offset:Int64.max,length:1) }
        #expect(throws:(any Error).self) { try ByteSpan(offset:-1,length:1) }
    }
    @Test func mediaOriginsPreserveQueriesAndRejectLookalikesCredentialsAndPorts() {
        #expect(MediaOrigin.normalizedURL("http://media.bilivideo.com/a.mp4?signature=A%2BB")?.absoluteString == "https://media.bilivideo.com/a.mp4?signature=A%2BB")
        for text in ["https://bilivideo.com.evil.test/a","https://bilivideo.com@localhost/a","https://localhost/a","https://127.0.0.1/a","https://media.bilivideo.com:8080/a","file:///tmp/a","https://user:pass@media.bilivideo.com/a","https://media.bilivideo.com/a#fragment"] {
            #expect(MediaOrigin.normalizedURL(text) == nil)
        }
    }
    @Test(arguments:[false,true]) func indexUsesAbsoluteBoxEndAnd64BitPresentation(large: Bool) throws {
        let data = indexVector(large:large)
        let result = try SegmentIndex.decode(data,fileOffset:300,fileLength:500)
        #expect(result.timescale == 1000); #expect(result.duration == 3)
        #expect(result.presentationStart == (large ? 4_294_967_300 : 50))
        #expect(result.fragments.map(\.bytes.offset) == (large ? [377,388] : [369,380]))
        #expect(result.fragments.map(\.bytes.length) == [11,13]); #expect(result.fragments[0].randomAccess)
    }
    @Test func truncatedAndOverflowedIndexNeverReadsOutsideItsBox() {
        let complete = indexVector(large:true)
        for count in 0..<complete.count {
            #expect(throws:(any Error).self) { try SegmentIndex.decode(complete.prefix(count),fileOffset:300,fileLength:500) }
        }
        #expect(throws:(any Error).self) { try SegmentIndex.decode(indexVector(large:true,offset:UInt64.max),fileOffset:300,fileLength:500) }
        #expect(throws:(any Error).self) { try SegmentIndex.decode(complete,fileOffset:300,fileLength:380) }
        #expect(throws:(any Error).self) { try SegmentIndex.decode(indexVector(large:false,indirect:true),fileOffset:300,fileLength:500) }
        #expect(throws:(any Error).self) { try SegmentIndex.decode(indexVector(large:false,scale:0),fileOffset:300,fileLength:500) }
    }
    @Test func rangeReceiptsValidateIdentityBeforeAcceptingBody() throws {
        let span = try ByteSpan(offset:10,length:5)
        func reply(_ fields:[String:String],_ status:Int = 206) -> HTTPURLResponse {
            HTTPURLResponse(url:URL(string:"https://fixture.bilivideo.com/r")!,statusCode:status,httpVersion:nil,headerFields:fields)!
        }
        let valid = ["Content-Range":"bytes 10-14/30","Content-Type":"video/mp4"]
        #expect(try RangeReceipt.check(reply(valid),span:span,total:30).total == 30)
        for patch in [["Content-Range":"bytes 9-13/30"],["Content-Range":"bytes 10-14/*"],["Content-Length":"4"],["Content-Encoding":"gzip"],["Content-Type":"text/html"]] {
            #expect(throws:(any Error).self) { try RangeReceipt.check(reply(valid.merging(patch) { _,new in new }),span:span,total:30) }
        }
        #expect(throws:(any Error).self) { try RangeReceipt.check(reply(valid,200),span:span,total:30) }
        #expect(throws:(any Error).self) { try RangeReceipt.check(reply(valid),span:span,total:31) }
    }
    @Test func requestParserRejectsBodiesPipeliningAndAmbiguousHeaders() throws {
        let good = "GET /session/v/seg/1.m4s HTTP/1.1\r\nHost: 127.0.0.1:123\r\nRange: bytes=1-4\r\n\r\n"
        #expect(try MediaRequest.decode(Data(good.utf8)).headers["range"] == "bytes=1-4")
        for bad in [good+good,good.replacingOccurrences(of:"Range:",with:"Host:"),good.replacingOccurrences(of:"Range: bytes=1-4",with:"Content-Length: 1"),good.replacingOccurrences(of:"Range: bytes=1-4",with:"Transfer-Encoding: chunked"),good.replacingOccurrences(of:"/session",with:"/%2e%2e/session")] {
            #expect(throws:(any Error).self) { try MediaRequest.decode(Data(bad.utf8)) }
        }
    }
    @Test func cancelledBudgetWaiterDoesNotConsumeOrLeakAPermit() async throws {
        let budget = DeliveryBudget(); try await budget.acquire(); try await budget.acquire()
        let waiting = Task { try await budget.acquire() }
        for _ in 0..<10 { await Task.yield() }; waiting.cancel()
        do { try await waiting.value; Issue.record("等待应取消") } catch is CancellationError {}
        await budget.release(); await budget.release()
        try await budget.acquire(); await budget.release()
    }
    @Test func cancelledPreparationAndWrongTrackKindCannotPublishAStream() async throws {
        let f = try MediaFixtures()
        await #expect(throws:(any Error).self) { try await NativePlaybackBridge(reader:f.reader).prepare(video:f.audio,audio:f.audio) }
        #expect(await f.reader.reads.isEmpty)
        await f.reader.setDelay(.seconds(5))
        let pending = Task { try await NativePlaybackBridge(reader:f.reader).prepare(video:f.video,audio:f.audio) }
        for _ in 0..<1000 { if await !f.reader.reads.isEmpty { break }; await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("不能发布已取消播放项") } catch is CancellationError {}
    }
}

/// Hand-authored numerical oracle: free(8), sidx(56 or 64), first_offset=5,
/// references (11 bytes, 1000 ticks), (13 bytes, 2000 ticks). Not built by the parser.
private func indexVector(large: Bool, offset: UInt64 = 5, indirect: Bool = false, scale: UInt64 = 1000) -> Data {
    func uint(_ value:UInt64,_ width:Int) -> Data { Data((0..<width).reversed().map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
    var body = Data([large ? 1:0,0,0,0]); body += uint(1,4); body += uint(scale,4)
    body += uint(large ? 4_294_967_300:50,large ? 8:4); body += uint(offset,large ? 8:4)
    body += uint(0,2); body += uint(2,2)
    body += uint(indirect ? 0x8000_000b:11,4); body += uint(1000,4); body += uint(0x9000_0000,4)
    body += uint(13,4); body += uint(2000,4); body += uint(0,4)
    return uint(8,4)+Data("free".utf8)+uint(UInt64(body.count+8),4)+Data("sidx".utf8)+body
}
