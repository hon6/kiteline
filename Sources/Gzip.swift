import Compression
import Foundation

/// gzip 压缩（给手机的网页、接口 JSON 用）：Compression 框架出原始 DEFLATE，外面包上 gzip 头尾
enum Gzip {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var gz = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])   // 头：deflate、无文件名、Unix
        gz.append(out.prefix(written))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        gz.append(Data(bytes: &crc, count: 4))
        gz.append(Data(bytes: &size, count: 4))
        return gz
    }

    /// 值得压的：文本类、超过 1KB、还没压过
    static func worthCompressing(_ response: HTTPResponse) -> Bool {
        guard response.body.count > 1024, response.headers["Content-Encoding"] == nil else { return false }
        let type = response.headers["Content-Type"] ?? ""
        return ["text/", "application/json", "javascript", "image/svg", "manifest", "application/xml"].contains { type.contains($0) }
    }
}
