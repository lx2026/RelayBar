import Foundation
import NIOCore

public enum SFTPError: Error, Sendable, Equatable {
    case endOfFile, noSuchFile, permissionDenied, status(UInt32), malformedPacket
    case fileChanged, isDirectory, symbolicLink
    case invalidPath, handleLimit, handleInUse, closed
}

extension ByteBuffer {
    mutating func putString(_ bytes: some Collection<UInt8>) {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func number<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        guard let value = readInteger(as: T.self) else { throw SFTPError.malformedPacket }
        return value
    }

    mutating func field() throws -> [UInt8] {
        let length = try number(UInt32.self)
        guard let bytes = readBytes(length: Int(length)) else { throw SFTPError.malformedPacket }
        return bytes
    }
}

struct Packet: Sendable {
    var type: UInt8
    var body: ByteBuffer
    func expect(_ type: UInt8) throws -> ByteBuffer {
        var bytes = body
        if self.type == 101 {
            let code = try bytes.number(UInt32.self)
            switch code {
            case 0 where type == 101: return bytes
            case 0: throw SFTPError.malformedPacket
            case 1: throw SFTPError.endOfFile
            case 2: throw SFTPError.noSuchFile
            case 3: throw SFTPError.permissionDenied
            default: throw SFTPError.status(code)
            }
        }
        guard self.type == type else { throw SFTPError.malformedPacket }
        return bytes
    }
}

public struct FileAttributes: Sendable, Equatable {
    public let size: UInt64?
    public let userID: UInt32?
    public let groupID: UInt32?
    public let permissions: UInt32?
    public let accessTime: UInt32?
    public let modificationTime: UInt32?

    init(_ buffer: inout ByteBuffer) throws {
        let flags = try buffer.number(UInt32.self)
        guard flags & ~0x8000000f == 0 else { throw SFTPError.malformedPacket }
        size = flags & 1 != 0 ? try buffer.number() : nil
        userID = flags & 2 != 0 ? try buffer.number() : nil
        groupID = flags & 2 != 0 ? try buffer.number() : nil
        permissions = flags & 4 != 0 ? try buffer.number() : nil
        accessTime = flags & 8 != 0 ? try buffer.number() : nil
        modificationTime = flags & 8 != 0 ? try buffer.number() : nil
        if flags & 0x80000000 != 0 {
            for _ in 0..<(try buffer.number(UInt32.self)) {
                _ = try buffer.field()
                _ = try buffer.field()
            }
        }
    }
}

public struct DirectoryEntry: Sendable {
    public let filename: Data
    public var displayName: String { String(decoding: filename, as: UTF8.self) }
    public let attributes: FileAttributes
}

func pathPacket(_ path: String) throws -> ByteBuffer {
    try pathPacket(Data(path.utf8))
}

func pathPacket(_ path: Data) throws -> ByteBuffer {
    guard path.first == 47, path.count <= 32768,
          String(decoding: path, as: UTF8.self).rangeOfCharacter(from: .controlCharacters) == nil else { throw SFTPError.invalidPath }
    var bytes = ByteBuffer()
    bytes.putString(path)
    return bytes
}

/// The same path, regular-file kind, size and modification time displayed at selection.
public struct SFTPFileFingerprint: Sendable {
    let path: Data
    let size: UInt64
    let modificationTime: UInt32

    public init?(path: Data, attributes: FileAttributes) {
        guard attributes.permissions.map({ $0 & 0o170000 }) == 0o100000,
              let size = attributes.size, let modificationTime = attributes.modificationTime else { return nil }
        self.path = path
        self.size = size
        self.modificationTime = modificationTime
    }

    public init?(path: String, attributes: FileAttributes) {
        self.init(path: Data(path.utf8), attributes: attributes)
    }
}
