// BetaConfig.swift
// Per-user beta configuration — only compiled into beta builds.
// The token placeholder is replaced by build-beta.sh via sed for each user's DMG.

#if BETA_BUILD

import Foundation

enum BetaConfig {
    /// Per-user beta token, baked in at build time.
    /// build-beta.sh replaces BETA_TOKEN_PLACEHOLDER with the actual token.
    static let userToken: String = {
        let token = "BETA_TOKEN_PLACEHOLDER"
        // Security: fail fast if build-beta.sh forgot to substitute the token.
        // Shipping the literal placeholder would allow unauthenticated access to beta
        // endpoints under the BETA_TOKEN_PLACEHOLDER identity.
        precondition(
            !token.hasSuffix("PLACEHOLDER"),
            "BetaConfig.userToken was not replaced by build-beta.sh — do not ship this build"
        )
        return token
    }()

    /// Proxy base URL for beta-only proxy traffic.
    static let proxyBaseURL = "https://draft-proxy.tz427gsydr.workers.dev"
}

#endif
