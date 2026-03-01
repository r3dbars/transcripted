// BetaConfig.swift
// Per-user beta configuration — only compiled into beta builds.
// The token placeholder is replaced by build-beta.sh via sed for each user's DMG.

#if BETA_BUILD

import Foundation

enum BetaConfig {
    /// Per-user beta token, baked in at build time.
    /// build-beta.sh replaces BETA_TOKEN_PLACEHOLDER with the actual token.
    static let userToken = "BETA_TOKEN_PLACEHOLDER"

    /// Proxy base URL — all API calls route through here instead of api.anthropic.com
    static let proxyBaseURL = "https://draft-proxy.YOUR-SUBDOMAIN.workers.dev"

    /// Current app version — compared against /config min_version to prompt updates.
    /// Bump this in each release. build-beta.sh can also inject it via sed.
    static let appVersion = "1.0.1"

    /// Where to download the latest DMG (GitHub Releases or similar)
    static let updateURL = "https://github.com/r3dbars/draft-releases/releases/latest"
}

#endif
