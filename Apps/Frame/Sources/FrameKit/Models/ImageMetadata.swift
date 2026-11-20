import BridgeProtocol
import Foundation
import PreviewSupport

public typealias MetadataRow = PreviewSupport.MetadataRow

public struct ImageMetadata: Hashable, Sendable {
  public var prompt: String?
  public var negativePrompt: String?
  public var identity: [MetadataRow]
  public var aiGeneration: [MetadataRow]
  public var capture: [MetadataRow]
  public var embedded: [MetadataRow]
  public var sidecarText: String?
  public var companions: [BridgeCompanionText] = []

  public init(
    prompt: String? = nil,
    negativePrompt: String? = nil,
    identity: [MetadataRow] = [],
    aiGeneration: [MetadataRow] = [],
    capture: [MetadataRow] = [],
    embedded: [MetadataRow] = []
  ) {
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.identity = identity
    self.aiGeneration = aiGeneration
    self.capture = capture
    self.embedded = embedded
  }
}
