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
        // Crash early in debug/test if build-beta.sh did not substitute the token.
        assert(token != "BETA_TOKEN_PLACEHOLDER",
               "BetaConfig.userToken was not substituted — run build-beta.sh before use")
        return token
    }()

}

#endif
