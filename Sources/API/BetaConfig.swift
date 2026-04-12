// BetaConfig.swift
// Per-user beta configuration — only compiled into beta builds.
// The token placeholder is replaced by build-beta.sh via sed for each user's DMG.

#if BETA_BUILD

import Foundation

enum BetaConfig {
    /// Per-user beta token, baked in at build time.
    /// build-beta.sh replaces BETA_TOKEN_PLACEHOLDER with the actual token.
    static let userToken = "BETA_TOKEN_PLACEHOLDER"

    /// Proxy base URL for beta-only telemetry and proxy traffic.
    static let proxyBaseURL = "https://draft-proxy.tz427gsydr.workers.dev"
}

#endif
