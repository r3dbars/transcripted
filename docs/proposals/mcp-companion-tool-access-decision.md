# MCP companion tool access: owner decision

Status: unselected proposal for REVIEW.md item TOOLS-MCP-6. This document
changes no tools, grants, defaults, client configuration, or published listing.

## The product choice

Decide whether ordinary MCP connections should offer meeting controls and live
text, and whether enabling them in Transcripted should cover every such client.
The current listing describes saved-context search as read-only while the same
server also advertises companion tools. Correcting that mismatch requires a
clear choice about the intended surface and consent.

## Current source evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `ToolHandlers.swift` appends `CompanionTools.tools` to the tool list and calls
  the companion interceptor for ordinary and companion-mode clients alike.
  `companionMode` currently withholds the legacy audio widget; it does not
  restrict these nine companion tools to that mode.
- `CompanionTools.swift` marks `start_meeting`, `stop_meeting`, and
  `set_live_context_sharing` as writes. The remaining companion tools include
  recording status, saved-context browsing, and live-context reads.
- The bundle's `Tools/TranscriptedMCP/mcpb/manifest.json` describes the extension
  as read-only and lists the twenty saved-context tools without the nine
  companion tools. The root `server.json` also describes read-only search.
  These are checked-in descriptions, not a live registry readback.
- Native controls require the app's enabled companion connection and relevant
  permission. `CompanionPreferences` stores shared connection, meeting-control,
  and live-sharing booleans; the native service does not receive an MCP-host
  identity with which to distinguish grants for individual hosts.
- The local socket checks the peer UID and authenticates requests with the
  connection token. These protections remain necessary. A mode environment
  flag is not an authenticated host identity or a per-client permission grant.
- `CompanionConnectionService` separately checks meeting-control permission for
  starting and stopping, validates the current session for stopping and sharing,
  and requires permission plus per-session sharing for live transcript reads.
  A tool being advertised is not evidence that an unauthenticated client can
  record or read live text. The shared grant scope is the question here.
- The MCP start tool sends `share_live: false`. Opening the companion does not
  start recording or enable sharing. Preserve these explicit-action boundaries.

No running companion, local socket, real preferences, recordings, or client
configuration was inspected or exercised for this source inventory.

## Choose the intended behavior

All options remain unselected; the owner may revise them.

- [ ] A. Keep ordinary MCP clients on the saved-context surface. Offer companion
      tools only in the intended companion mode, with matching list and dispatch
      gates. Treat this as a product exposure rule, not a new authentication
      boundary; preserve native permission and session checks.
- [ ] B. Keep companion tools available to ordinary MCP clients too. Update the
      bundle, registry metadata, setup docs, and consent copy to disclose the
      shared grant scope and each capability. Specify how existing users are
      informed before relying on their earlier companion permission choices.
- [ ] C. Design separate client grants. Define authenticated client identity,
      grant issuance, revocation, migration, and UI before implementing it. A
      host-supplied label or environment flag alone does not supply that design.

For any choice, preserve session-specific live sharing and explicit user actions.
Test listing and dispatch together, including denied calls, disabled connection,
stale sessions, and switching off a grant. Keep the manifest, registry metadata,
installed-helper behavior, and host handshake contracts consistent. Use isolated
fixtures first; report actual host-client proof separately.

This worksheet does not select a policy or complete TOOLS-MCP-6. Owner selection
and any migration or consent conditions: pending.
