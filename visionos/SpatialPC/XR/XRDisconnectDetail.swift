import Foundation

/// The public LocalizedError description only; never reflects SDK private state.
struct XRDisconnectDetail: Codable, Sendable {
    let state: String
    let text: String?
    let truncated: Bool
    let redacted: Bool

    init(_ description: String?, privateValues: [String] = []) {
        guard let description else {
            state = "absent"; text = nil; truncated = false; redacted = false; return
        }
        guard !description.isEmpty else {
            state = "empty"; text = ""; truncated = false; redacted = false; return
        }
        // Do not partially retain a huge opaque payload or spend unbounded time
        // applying expressions. Redact before truncation so split tokens cannot leak.
        guard description.utf8.count <= 16_384 else {
            state = "oversize"; text = nil; truncated = true; redacted = true; return
        }
        var safe = description
        for value in privateValues.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            safe = safe.replacingOccurrences(of: value, with: "[redacted]", options: .caseInsensitive)
        }
        for pattern in [
            #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#,
            #"(?i)["']?\b(?:token|password|secret|pin|code)["']?\s*[=:]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}]+)"#,
            #"(?i)\bbearer\s+[^\s,;]+"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#,
            #"(?i)(?<![a-z0-9])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.%]+"#,
            #"[A-Za-z0-9_+/=-]{32,}"#
        ] {
            safe = safe.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        safe = String(safe.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
        state = "present"; truncated = safe.count > 1024
        redacted = safe != description
        text = String(safe.prefix(1024))
    }
}
