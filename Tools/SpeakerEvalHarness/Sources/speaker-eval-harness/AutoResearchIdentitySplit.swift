import Foundation

// MARK: - Stable identity split

func corpusFamily(_ corpus: String) -> String {
    if corpus.hasPrefix("ami_") { return "ami" }
    if corpus.hasPrefix("voxceleb_") { return "voxceleb" }
    if corpus.hasPrefix("voxconverse_") { return "voxconverse" }
    return corpus.split(separator: "_").first.map(String.init) ?? corpus
}

func identitySplit(family: String, truth: String) -> ResearchSplit {
    let bucket = stableFNV1a("\(family)|\(truth)") % 10
    switch bucket {
    case 0...5: return .train
    case 6...7: return .dev
    default: return .holdout
    }
}

private func stableFNV1a(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

func deterministicProfileId(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llx", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
