import CZlib
import Foundation

public enum PNGTextReader {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

  public static func read(from url: URL) throws -> [String: String] {
    read(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
  }

  public static func read(data: Data) -> [String: String] {
    guard data.count >= signature.count, data.prefix(signature.count) == signature else {
      return [:]
    }
    var offset = data.startIndex + signature.count
    var values: [String: String] = [:]

    var remaining = PreviewLimits.pngText
    while remaining > 0, offset + 12 <= data.endIndex {
      let length = Int(readUInt32(data, at: offset))
      let typeStart = offset + 4
      let payloadStart = typeStart + 4
      let payloadEnd = payloadStart + length
      let chunkEnd = payloadEnd + 4
      guard chunkEnd <= data.endIndex else { break }

      let typeData = data[typeStart..<(typeStart + 4)]
      let type = String(data: typeData, encoding: .ascii) ?? ""
      let payload = data[payloadStart..<payloadEnd]

      var entry: (key: String, value: String, bytes: Int)?
      switch type {
      case "tEXt":
        entry = parseText(payload)
      case "zTXt":
        entry = parseCompressedText(payload)
      case "iTXt":
        entry = parseInternationalText(payload)
      case "IEND":
        return values
      default:
        break
      }
      if let entry, entry.bytes <= min(PreviewLimits.pngChunk, remaining) {
        values[entry.key] = entry.value
        remaining -= entry.bytes
      }
      offset = chunkEnd
    }
    return values
  }

  private static func parseText(_ payload: Data) -> (key: String, value: String, bytes: Int)? {
    guard let separator = payload.firstIndex(of: 0) else { return nil }
    guard (1...79).contains(separator - payload.startIndex) else { return nil }
    let key = decodeLatin1(payload[..<separator])
    let bytes = payload[payload.index(after: separator)...]
    guard bytes.count <= PreviewLimits.pngChunk else { return nil }
    let value = decodeLatin1(bytes)
    guard !key.isEmpty else { return nil }
    return (key, value, bytes.count)
  }

  private static func parseCompressedText(_ payload: Data) -> (key: String, value: String, bytes: Int)? {
    guard let separator = payload.firstIndex(of: 0) else { return nil }
    let methodIndex = payload.index(after: separator)
    guard methodIndex < payload.endIndex, payload[methodIndex] == 0 else { return nil }
    let compressedStart = payload.index(after: methodIndex)
    let compressed = payload[compressedStart...]
    guard let decompressed = decompressZlib(compressed) else { return nil }
    guard (1...79).contains(separator - payload.startIndex) else { return nil }
    let key = decodeLatin1(payload[..<separator])
    let value = decodeLatin1(decompressed[...])
    guard !key.isEmpty else { return nil }
    return (key, value, decompressed.count)
  }

  private static func parseInternationalText(_ payload: Data) -> (key: String, value: String, bytes: Int)? {
    guard let keywordEnd = payload.firstIndex(of: 0) else { return nil }
    guard (1...79).contains(keywordEnd - payload.startIndex) else { return nil }
    let flagIndex = payload.index(after: keywordEnd)
    let methodIndex = payload.index(after: flagIndex)
    guard methodIndex < payload.endIndex, payload[methodIndex] == 0 else { return nil }

    var cursor = payload.index(after: methodIndex)
    guard let languageEnd = payload[cursor...].firstIndex(of: 0) else { return nil }
    cursor = payload.index(after: languageEnd)
    guard let translatedEnd = payload[cursor...].firstIndex(of: 0) else { return nil }
    cursor = payload.index(after: translatedEnd)

    let textData = payload[cursor...]
    let decoded: Data
    if payload[flagIndex] == 1 {
      guard let decompressed = decompressZlib(textData) else {
        return nil
      }
      decoded = decompressed
    } else {
      guard payload[flagIndex] == 0, textData.count <= PreviewLimits.pngChunk else { return nil }
      decoded = textData
    }

    let key = decodeLatin1(payload[..<keywordEnd])
    guard let value = String(data: decoded, encoding: .utf8), !key.isEmpty else { return nil }
    return (key, value, decoded.count)
  }

  private static func decompressZlib(_ compressed: Data) -> Data? {
    guard !compressed.isEmpty else { return nil }
    var length = uLongf(PreviewLimits.pngChunk)
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
