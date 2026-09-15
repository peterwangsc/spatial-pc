import Testing
@testable import XRCore

struct XRDisconnectDetailTests {
    @Test func retainsUsefulPublicExplanation() {
        let result = XRDisconnectDetail("The requested configuration is incompatible (error 17).")
        #expect(result.text == "The requested configuration is incompatible (error 17).")
        #expect(!result.redacted && !result.truncated)
    }
    @Test func distinguishesMissingEmptyAndOversize() {
        #expect(XRDisconnectDetail(nil).state == "absent")
        #expect(XRDisconnectDetail("").state == "empty")
        let huge = XRDisconnectDetail(String(repeating: "a", count: 16_385))
        #expect(huge.state == "oversize" && huge.text == nil)
    }
    @Test func redactsBeforeTruncation() {
        let result = XRDisconnectDetail("Denied at https://pc.example/path?token=secret 192.168.86.20:48322 fe80::1234 token=short-secret Bearer abcdef My PC " + String(repeating:"a",count:64), privateValues:["My PC"])
        for secret in ["pc.example", "192.168", "fe80", "short-secret", "abcdef", "My PC", String(repeating:"a",count:32)] {
            #expect(result.text?.contains(secret) == false)
        }
        #expect(result.redacted)
    }
    @Test func boundsExportAndRemovesControlCharacters() {
        let result = XRDisconnectDetail(String(repeating:"message ",count:200) + "\n\u{001b}")
        #expect(result.text?.count == 1024)
        #expect(result.truncated)
        #expect(result.text?.contains("\u{001b}") == false)
    }
    @Test func redactsQuotedCredentialValues() {
        let result = XRDisconnectDetail(#"{"token":"short-secret","password": "short secret", 'pin': '1234', "secret":"escaped\"value"}"#)
        for secret in ["short-secret", "short secret", "1234", "escaped", "value"] {
            #expect(result.text?.contains(secret) == false)
        }
        #expect(result.redacted)
    }
}
