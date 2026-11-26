import CoreML
import FluidAudio
import Foundation

// Load only the compiled models already on this Mac. The library's default
// loader can download a different revision of the models.
func localModels() async throws -> OfflineDiarizerModels {
    let folder = OfflineDiarizerModels.defaultModelsDirectory().appending(path: "speaker-diarization")
    func model(_ name: String, cpu: Bool = false) async throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = cpu ? .cpuOnly : .all
        return try await MLModel.load(contentsOf: folder.appending(path: name + ".mlmodelc"), configuration: config)
    }
    struct Tensor: Decodable { let data_base64: Data }
    struct Parameters: Decodable { let tensors: [String: Tensor] }
    let data = try Data(contentsOf: folder.appending(path: "plda-parameters.json"))
    let parameters = try JSONDecoder().decode(Parameters.self, from: data)
    guard let bytes = parameters.tensors["psi"]?.data_base64, !bytes.isEmpty,
          bytes.count.isMultiple(of: MemoryLayout<Float>.size) else { throw CocoaError(.fileReadCorruptFile) }
    let psi = bytes.withUnsafeBytes { buffer in
        stride(from: 0, to: buffer.count, by: 4).map { Double(buffer.loadUnaligned(fromByteOffset: $0, as: Float.self)) }
    }
    return try await OfflineDiarizerModels(segmentationModel: model("Segmentation"), fbankModel: model("FBank", cpu: true),
        embeddingModel: model("Embedding"), pldaRhoModel: model("PldaRho"), pldaPsi: psi, compilationDuration: 0)
}

struct Turn: Encodable { let start, end: Float; let voice: String }
do {
    guard (4...5).contains(CommandLine.arguments.count) else { throw CocoaError(.fileReadInvalidFileName) }
    var config = OfflineDiarizerConfig.default
    if let minimum = Int(CommandLine.arguments[3]), minimum >= 2 { config.clustering.minSpeakers = minimum }
    if CommandLine.arguments.count == 5 { config.embeddingExportPath = CommandLine.arguments[4] }
    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: try await localModels())
    let result = try await manager.process(URL(fileURLWithPath: CommandLine.arguments[1]))
    let turns = result.segments.map { Turn(start: $0.startTimeSeconds, end: $0.endTimeSeconds, voice: $0.speakerId) }
    try JSONEncoder().encode(turns).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
