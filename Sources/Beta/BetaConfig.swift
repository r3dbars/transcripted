// BetaConfig.swift
// Beta-build compile-time configuration. Currently empty.
//
// History: this file used to ship a per-user bearer token baked in at build time
// via sed/perl substitution in build-beta.sh. That token authenticated the app
// against an archived proxy worker that is no longer part of the live product.
//
// The proxy client is no longer part of the app target (BetaTelemetry and the
// /config update-check flow are gone — Sparkle handles updates, Sentry handles
// crash reports, PostHog handles analytics). The token was therefore dead code
// that still ended up recoverable from the Mach-O binary via `strings` for
// anyone with read access to the bundle. It has been removed.
//
// If beta-only auth comes back, generate the secret at first launch into the
// Keychain rather than baking it into the binary, and pair it to the server via
// a short-lived enrollment code handed out-of-band.

#if BETA_BUILD

import Foundation

enum BetaConfig {
    // Intentionally empty — see file header.
}

#endif
