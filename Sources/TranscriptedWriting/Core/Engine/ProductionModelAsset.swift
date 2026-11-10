import Foundation

/// The single immutable pin for the production model asset. It lives in Core
/// so the pin has one home; `ModelDescriptor` (Runtime) builds the download
/// descriptor from it.
public enum ProductionModelAsset {
    public static let identifier = "gemma-4-e2b-q4km"
    public static let revision = "3762686d74ff8db6c98f8d3c389f56fbdf994d5a"
    public static let repository = "mradermacher/gemma-4-E2B-GGUF"
    public static let fileName = "gemma-4-E2B.Q4_K_M.gguf"
    public static let expectedBytes: Int64 = 3_427_861_984
    public static let sha256 = "389c868898bffed97fd178646f88562cafecc6f60983a636bac53b131fd068a2"

    public static var downloadURL: URL {
        URL(
            string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)"
        )!
    }
}
