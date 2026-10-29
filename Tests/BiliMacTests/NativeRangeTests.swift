import Foundation
import Testing
@testable import BiliMacMedia

@Suite(.serialized) struct NativeRangeTests {
    private let url = URL(string:"https://fixture.bilivideo.com/own/test.mp4")!
    private var reader: HTTPMediaReader { HTTPMediaReader(configuration:{
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaRangeProtocol.self]; return config
    }) }
    @Test func productionTransferStripsCredentialsAndAcceptsExactBytesWithoutContentLength() async throws {
        MediaRangeProtocol.reset(status:206,fields:["Content-Range":"bytes 2-5/20","Content-Type":"video/mp4"],body:Data([1,2,3,4]))
        let result = try await reader.read(url:url,span:ByteSpan(offset:2,length:4),completeLength:20,
                                         headers:["User-Agent":"test-agent","Referer":"https://www.bilibili.com/","Cookie":"secret","Authorization":"secret"])
        #expect(result.bytes == Data([1,2,3,4])); #expect(result.completeLength == 20)
        let request = try #require(MediaRangeProtocol.request)
        #expect(request.value(forHTTPHeaderField:"Cookie") == nil); #expect(request.value(forHTTPHeaderField:"Authorization") == nil)
        #expect(request.value(forHTTPHeaderField:"Range") == "bytes=2-5")
        #expect(request.value(forHTTPHeaderField:"User-Agent") == "test-agent")
        #expect(request.value(forHTTPHeaderField:"Accept-Encoding") == "identity")
    }
    @Test func ignoredRangeShortBodyWrongLengthAndHTMLNeverBecomeMedia() async throws {
        let valid = ["Content-Range":"bytes 2-5/20","Content-Type":"video/mp4"]
        for (status,fields,body) in [
            (200,valid,Data([1,2,3,4])),
            (206,valid,Data([1,2,3])),
            (206,valid,Data([1,2,3,4,5])),
            (206,valid.merging(["Content-Range":"bytes 2-5/21"]) { _,b in b },Data([1,2,3,4])),
            (206,valid.merging(["Content-Type":"text/html"]) { _,b in b },Data([1,2,3,4]))] {
            MediaRangeProtocol.reset(status:status,fields:fields,body:body)
            await #expect(throws:(any Error).self) { try await reader.read(url:url,span:ByteSpan(offset:2,length:4),completeLength:20,headers:[:]) }
        }
    }
    @Test func invalidSourceOversizedRangeAndPrecancelledReadNeverReachTransport() async throws {
        MediaRangeProtocol.reset(status:206,fields:[:],body:Data())
        await #expect(throws:(any Error).self) { try await reader.read(url:URL(string:"https://localhost/a")!,span:ByteSpan(offset:0,length:4),completeLength:nil,headers:[:]) }
        await #expect(throws:(any Error).self) { try await reader.read(url:url,span:ByteSpan(offset:0,length:16*1_024*1_024+1),completeLength:nil,headers:[:]) }
        let pending = Task { try await Task.sleep(for:.seconds(5)); return try await reader.read(url:url,span:ByteSpan(offset:0,length:4),completeLength:nil,headers:[:]) }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("取消应失败") } catch is CancellationError {}
        #expect(MediaRangeProtocol.request == nil)
    }
}
private final class MediaRangeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: (Int,[String:String],Data) = (500,[:],Data())
    private static var last: URLRequest?
    static var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return last }
    static func reset(status:Int,fields:[String:String],body:Data) { lock.lock(); defer { lock.unlock() }; response = (status,fields,body); last = nil }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.last = request; let value = Self.response; Self.lock.unlock()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:value.0,httpVersion:nil,headerFields:value.1)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:value.2); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
