import Foundation

/// Newer versions of macOS and iOS often leave `message.text` empty and store the
/// message text inside `message.attributedBody`, an NSAttributedString serialized
/// in Apple's legacy "typedstream" format. This pulls the plain string out of it.
public enum AttributedBodyDecoder {
    public static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        for className in ["NSString", "NSMutableString"] {
            if let text = extract(after: Array(className.utf8), in: bytes) {
                return text
            }
        }
        return nil
    }

    private static func extract(after marker: [UInt8], in bytes: [UInt8]) -> String? {
        guard let start = firstIndex(of: marker, in: bytes) else { return nil }
        var i = start + marker.count

        // The string's bytes follow a '+' type tag shortly after the class name.
        let limit = min(bytes.count, i + 16)
        while i < limit && bytes[i] != 0x2B { i += 1 }
        guard i < limit else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        // typedstream integer: < 0x80 is the value itself, 0x81 = int16 follows, 0x82 = int32 follows.
        var length: Int
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8) | (Int(bytes[i + 3]) << 16) | (Int(bytes[i + 4]) << 24)
            i += 5
        default:
            length = Int(bytes[i])
            i += 1
        }

        guard length > 0, i + length <= bytes.count else { return nil }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        let first = pattern[0]
        var i = 0
        let last = bytes.count - pattern.count
        while i <= last {
            if bytes[i] == first {
                var match = true
                for j in 1..<pattern.count where bytes[i + j] != pattern[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
