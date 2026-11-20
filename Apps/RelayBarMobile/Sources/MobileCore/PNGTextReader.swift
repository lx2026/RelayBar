import CZlib
import Foundation

enum PNGTextReader {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

  static func read(data: Data) -> [String: String] {
    guard data.count >= signature.count, data.prefix(signature.count) == signature else {
      return [:]
    }
    var offset = signature.count
    var values: [String: String] = [:]

    var remaining = 256_000
    while remaining > 0, offset + 12 <= data.count {
      let length = Int(readUInt32(data, at: offset))
      let typeStart = offset + 4
      let payloadStart = typeStart + 4
      let payloadEnd = payloadStart + length
      let chunkEnd = payloadEnd + 4
      guard length >= 0, chunkEnd <= data.count else { break }

      let typeData = data[typeStart..<(typeStart + 4)]
      let type = String(data: typeData, encoding: .ascii) ?? ""
      // Only text chunks are copied out of the mapped file; image data is skipped where it lies.
      func payload() -> Data { Data(data[payloadStart..<payloadEnd]) }

      var entry: (key: String, value: String)?
      switch type {
      case "tEXt":
        if length <= remaining { entry = parseText(payload()) }
      case "zTXt":
        if length <= remaining { entry = parseCompressedText(payload()) }
      case "iTXt":
        if length <= remaining { entry = parseInternationalText(payload()) }
      case "IEND":
        return values
      default:
        break
      }
      if let entry {
        values[entry.key] = String(entry.value.prefix(remaining))
        remaining -= min(remaining, entry.key.utf8.count + entry.value.utf8.count)
      }
      offset = chunkEnd
    }
    return values
  }

  private static func parseText(_ payload: Data) -> (key: String, value: String)? {
    guard let separator = payload.firstIndex(of: 0) else { return nil }
    let key = decodeLatin1(payload[..<separator])
    let value = decodeLatin1(payload[payload.index(after: separator)...])
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private static func parseCompressedText(_ payload: Data) -> (key: String, value: String)? {
    guard let separator = payload.firstIndex(of: 0) else { return nil }
    let methodIndex = payload.index(after: separator)
    guard methodIndex < payload.endIndex, payload[methodIndex] == 0 else { return nil }
    let compressedStart = payload.index(after: methodIndex)
    let compressed = Data(payload[compressedStart...])
    guard let decompressed = decompressZlib(compressed) else { return nil }
    let key = decodeLatin1(payload[..<separator])
    let value = decodeLatin1(decompressed[...])
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private static func parseInternationalText(_ payload: Data) -> (key: String, value: String)? {
    guard let keywordEnd = payload.firstIndex(of: 0) else { return nil }
    let flagIndex = payload.index(after: keywordEnd)
    let methodIndex = payload.index(after: flagIndex)
    guard methodIndex < payload.endIndex else { return nil }

    var cursor = payload.index(after: methodIndex)
    guard let languageEnd = payload[cursor...].firstIndex(of: 0) else { return nil }
    cursor = payload.index(after: languageEnd)
    guard let translatedEnd = payload[cursor...].firstIndex(of: 0) else { return nil }
    cursor = payload.index(after: translatedEnd)

    let textData = Data(payload[cursor...])
    let decoded: Data
    if payload[flagIndex] == 1 {
      guard payload[methodIndex] == 0, let decompressed = decompressZlib(textData) else {
        return nil
      }
      decoded = decompressed
    } else {
      decoded = textData
    }

    let key = decodeLatin1(payload[..<keywordEnd])
    let value = String(data: decoded, encoding: .utf8) ?? decodeLatin1(decoded[...])
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private static func decompressZlib(_ compressed: Data) -> Data? {
    guard !compressed.isEmpty else { return nil }
    var length: uLongf = 256_000
    var output = Data(count: Int(length))
    let status = output.withUnsafeMutableBytes { destination in
      compressed.withUnsafeBytes { source in
        uncompress(
          destination.bindMemory(to: UInt8.self).baseAddress, &length,
          source.bindMemory(to: UInt8.self).baseAddress, UInt(compressed.count))
      }
    }
    guard status == Z_OK else { return nil }
    output.count = Int(length)
    return output
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func decodeLatin1(_ data: Data.SubSequence) -> String {
    String(data: Data(data), encoding: .isoLatin1) ?? ""
  }
}
