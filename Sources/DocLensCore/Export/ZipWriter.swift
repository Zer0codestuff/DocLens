import Compression
import Foundation

/// Writes a ZIP archive with DEFLATE compression. Enough for Office Open XML packages.
public struct ZipWriter {
    private struct Entry {
        var name: Data
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var method: UInt16
        var offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        bytes.withUnsafeBytes { buf in
            for b in buf { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < input.count else { return nil }
        return out.prefix(written)
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func add(path: String, contents: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(contents)
        let deflated = Self.deflate(contents)
        let payload = deflated ?? contents
        let method: UInt16 = deflated == nil ? 0 : 8
        let offset = UInt32(data.count)
        append(UInt32(0x0403_4B50))
        append(UInt16(20)); append(UInt16(0x0800)); append(method)
        append(UInt16(0)); append(UInt16(0x21))
        append(crc); append(UInt32(payload.count)); append(UInt32(contents.count))
        append(UInt16(name.count)); append(UInt16(0))
        data.append(name)
        data.append(payload)
        entries.append(Entry(name: name, crc: crc, compressedSize: UInt32(payload.count), size: UInt32(contents.count),
                             method: method, offset: offset))
    }

    public mutating func add(path: String, text: String) { add(path: path, contents: Data(text.utf8)) }

    public mutating func finish() -> Data {
        let centralStart = UInt32(data.count)
        for e in entries {
            append(UInt32(0x0201_4B50))
            append(UInt16(20)); append(UInt16(20)); append(UInt16(0x0800)); append(e.method)
            append(UInt16(0)); append(UInt16(0x21))
            append(e.crc); append(e.compressedSize); append(e.size)
            append(UInt16(e.name.count)); append(UInt16(0)); append(UInt16(0))
            append(UInt16(0)); append(UInt16(0)); append(UInt32(0))
            append(e.offset)
            data.append(e.name)
        }
        let centralSize = UInt32(data.count) - centralStart
        append(UInt32(0x0605_4B50))
        append(UInt16(0)); append(UInt16(0))
        append(UInt16(entries.count)); append(UInt16(entries.count))
        append(centralSize); append(centralStart); append(UInt16(0))
        return data
    }
}
