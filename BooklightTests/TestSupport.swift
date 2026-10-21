import Compression
import Foundation
import zlib

/// Helpers shared by the tests: temp folders and a minimal ZIP writer.
enum TestSupport {
    static func makeTempDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BooklightTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 64-hex-character id like the SHA-256 ones the app uses.
    static func bookID(_ seed: Character = "a") -> String {
        String(repeating: seed, count: 64)
    }
}

/// Builds ZIP archives in memory, with stored or deflated entries.
struct ZipBuilder {
    struct File {
        var path: String
        var data: Data
        var deflate: Bool
    }

    var files: [File] = []

    mutating func add(_ path: String, _ text: String, deflate: Bool = false) {
        files.append(File(path: path, data: Data(text.utf8), deflate: deflate))
    }

    mutating func add(_ path: String, data: Data, deflate: Bool = false) {
        files.append(File(path: path, data: data, deflate: deflate))
    }

    func build() -> Data {
        var archive = Data()
        var central = Data()

        for file in files {
            let nameData = Data(file.path.utf8)
            let crc = UInt32(file.data.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(file.data.count)) })
            let body = file.deflate ? Self.rawDeflate(file.data) : file.data
            let method: UInt16 = file.deflate ? 8 : 0
            let offset = UInt32(archive.count)

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20))  // version needed
            archive.append(le16(0))  // flags
            archive.append(le16(method))
            archive.append(le16(0))  // time
            archive.append(le16(0))  // date
            archive.append(le32(crc))
            archive.append(le32(UInt32(body.count)))
            archive.append(le32(UInt32(file.data.count)))
            archive.append(le16(UInt16(nameData.count)))
            archive.append(le16(0))  // extra length
            archive.append(nameData)
            archive.append(body)

            central.append(le32(0x0201_4B50))
            central.append(le16(20))  // version made by
            central.append(le16(20))  // version needed
            central.append(le16(0))
            central.append(le16(method))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(body.count)))
            central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(nameData.count)))
            central.append(le16(0))  // extra
            central.append(le16(0))  // comment
            central.append(le16(0))  // disk
            central.append(le16(0))  // internal attrs
            central.append(le32(0))  // external attrs
            central.append(le32(offset))
            central.append(nameData)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0))
        archive.append(le16(0))
        archive.append(le16(UInt16(files.count)))
        archive.append(le16(UInt16(files.count)))
        archive.append(le32(UInt32(central.count)))
        archive.append(le32(centralOffset))
        archive.append(le16(0))
        return archive
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// Raw DEFLATE (what ZIP stores); `COMPRESSION_ZLIB` produces exactly that.
    private static func rawDeflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(
                &output, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(output.prefix(written))
    }
}
