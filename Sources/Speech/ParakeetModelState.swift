// ParakeetModelState.swift
// Deps-free so the fast-test runner can compile it alongside the warmup and
// first-run policy files, which take this type directly instead of keeping
// per-surface mirror enums in sync by hand.

import Foundation

enum ParakeetModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case cached
    case loading
    case ready
    case failed(String)
}

extension ParakeetModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .cached: return "cached"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}
