import Foundation
import CoreML
import Recognition

/// Shared model-loading path for the offline harness executables (`detect-dump`,
/// `video-dump`): compiles the `.mlpackage`, resolves compute units from the
/// `MJ_COMPUTE` env var, and wraps the result in a production `VisionRecognizer`.
/// Lifted verbatim out of `detect-dump` so both CLIs run the exact same model
/// path — behavior of `detect-dump` is unchanged, it just calls through here now.
public enum HarnessModel {
    /// `MJ_COMPUTE=cpu|cpuGPU|ane` overrides the default `.all` — the Mac GPU/ANE
    /// graph compiler can choke on large graphs where a device wouldn't; `cpu`
    /// isolates that.
    public static func resolveComputeUnits(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MLComputeUnits {
        switch environment["MJ_COMPUTE"] {
        case "cpu": return .cpuOnly
        case "cpuGPU": return .cpuAndGPU
        case "ane": return .cpuAndNeuralEngine   // device parity
        default: return .all
        }
    }

    /// Compiles `modelPath` and returns a ready `VisionRecognizer` at `threshold`.
    public static func loadRecognizer(modelPath: String, threshold: Double) async throws -> VisionRecognizer {
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = resolveComputeUnits()
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        return try VisionRecognizer(model: model, confidenceThreshold: threshold)
    }
}
