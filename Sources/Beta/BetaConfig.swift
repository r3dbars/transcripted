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
        // Security: assert the placeholder was substituted before the binary shipped.
        // A beta build produced without running build-beta.sh would carry the literal
        // placeholder, which leaks the substitution mechanism and may succeed against a
        // lenient backend check. assertionFailure fires in debug/test builds only; production
        // callers should gate on this value before making authenticated requests.
        assert(token != "BETA_TOKEN_PLACEHOLDER",
               "BetaConfig.userToken was not substituted — run build-beta.sh before use")
        return token
    }()

    /// Proxy base URL for beta-only proxy traffic.
    static let proxyBaseURL = "https://draft-proxy.tz427gsydr.workers.dev"
}

#endif
