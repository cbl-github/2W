import Foundation

/// 把任意编码的 feed 字节转成 UTF-8 字节，并把 XML 声明里的 encoding 改写为 utf-8。
/// 判定顺序（设计文档 §8 坑 4）：HTTP header charset → BOM → XML 声明 → UTF-8 严格 → GB18030 → UTF-8 lossy。
/// 必须在交给 XML 解析器之前完成。
enum CharsetDecoder {
    static func decodeToUTF8(_ data: Data, httpTextEncodingName: String?) -> Data {
        let text = decodeToString(data, httpTextEncodingName: httpTextEncodingName)
        return Data(normalizeXMLDeclaration(text).utf8)
    }

    static func decodeToString(_ data: Data, httpTextEncodingName: String?) -> String {
        if let name = httpTextEncodingName, let enc = encoding(fromIANA: name),
           let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = decodeBOM(data) { return s }
        if let name = xmlDeclaredEncoding(data), let enc = encoding(fromIANA: name),
           let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(decoding: data, as: UTF8.self) // lossy 兜底：替换非法序列
    }

    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private static func encoding(fromIANA name: String) -> String.Encoding? {
        // gb2312/gbk 的实际内容常超出标称字符集，统一按其超集 GB18030 解。
        let lower = name.lowercased()
        if ["gb2312", "gbk", "gb18030", "gb_2312-80", "euc-cn"].contains(lower) { return gb18030 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func decodeBOM(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        return nil
    }

    /// 在前 256 字节的 ASCII 视图里找 `encoding="…"`。XML 声明必须在文件头，扫前缀足够。
    private static func xmlDeclaredEncoding(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        guard let match = head.firstMatch(of: /encoding\s*=\s*["']([A-Za-z0-9._-]+)["']/) else { return nil }
        return String(match.1)
    }

    /// 内容已是 UTF-8，声明必须一致，否则解析器按旧编码读会乱码。
    static func normalizeXMLDeclaration(_ text: String) -> String {
        guard text.hasPrefix("<?xml") else { return text }
        guard let declEnd = text.range(of: "?>") else { return text }
        let decl = String(text[..<declEnd.upperBound])
        let fixed = decl.replacing(/encoding\s*=\s*["'][A-Za-z0-9._-]+["']/, with: "encoding=\"utf-8\"")
        return fixed + text[declEnd.upperBound...]
    }
}
