import Foundation

/// A zip archive, with each entry stored or deflated. CRCs are left at
/// zero; the reader checks sizes, not checksums.
func makeZip(_ entries: [(path: String, data: Data, deflate: Bool)]) -> Data {
    var archive = Data()
    var directory = Data()
    func append16(_ value: Int, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }
    func append32(_ value: Int, to data: inout Data) {
        append16(value & 0xFFFF, to: &data)
        append16(value >> 16 & 0xFFFF, to: &data)
    }
    for entry in entries {
        let stored = entry.deflate ? (try! (entry.data as NSData).compressed(using: .zlib)) as Data : entry.data
        let name = Data(entry.path.utf8)
        let offset = archive.count
        append32(0x0403_4B50, to: &archive)
        append16(20, to: &archive)
        append16(0x0800, to: &archive)
        append16(entry.deflate ? 8 : 0, to: &archive)
        append32(0, to: &archive)
        append32(0, to: &archive)
        append32(stored.count, to: &archive)
        append32(entry.data.count, to: &archive)
        append16(name.count, to: &archive)
        append16(0, to: &archive)
        archive.append(name)
        archive.append(stored)

        append32(0x0201_4B50, to: &directory)
        append16(20, to: &directory)
        append16(20, to: &directory)
        append16(0x0800, to: &directory)
        append16(entry.deflate ? 8 : 0, to: &directory)
        append32(0, to: &directory)
        append32(0, to: &directory)
        append32(stored.count, to: &directory)
        append32(entry.data.count, to: &directory)
        append16(name.count, to: &directory)
        append16(0, to: &directory)
        append16(0, to: &directory)
        append16(0, to: &directory)
        append16(0, to: &directory)
        append32(0, to: &directory)
        append32(offset, to: &directory)
        directory.append(name)
    }
    let directoryOffset = archive.count
    archive.append(directory)
    append32(0x0605_4B50, to: &archive)
    append16(0, to: &archive)
    append16(0, to: &archive)
    append16(entries.count, to: &archive)
    append16(entries.count, to: &archive)
    append32(directory.count, to: &archive)
    append32(directoryOffset, to: &archive)
    append16(0, to: &archive)
    return archive
}
