# BUILD-CI-3: duplicate MCP publishing-tool finding

BUILD-CI-3 and TOOLS-MCP-9 identify the same unpinned validator/publisher and
job-level repository-token scope in `.github/workflows/publish-mcp-registry.yml`.
The shared hardening proposal is [PR #2409](https://github.com/r3dbars/transcripted/pull/2409),
at commit `fc8bdf25b6a3689595c0005255f9ecc8f71ce1ec`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-MCP-9 remains its primary report ID.

The proposal pins checkout by commit, MCPB to 2.1.2 with a committed npm lockfile,
and MCP publisher to v1.8.8 with committed architecture-specific checksums.
The installer checks SHA-256 before extraction; the workflow uses the local
validator after `npm ci --ignore-scripts`. Repository `GH_TOKEN` moves to the
release download/upload steps and checkout disables persisted credentials.
These are proposed source changes, not proof of an installed or published artifact.

The release-only trigger, runner, job permissions and OIDC publishing flow remain.
OIDC is still job-wide: immutable tool selection and narrower repository-token
environment scope do not establish process privilege isolation. The report calls
this a hardening gap with no known exploit; this disposition makes no exploit claim.

The existing PR records offline fixtures and validator checks, but also records
canonical FAIL from explicit guard refusals and unresolved packaging input.
Full/native release integration and live publishing remain pending. Those are
#2409's recorded results, not tests rerun for this document or release certification.

At verification, #2409 is an open, unmerged draft. This dedicated BUILD-CI-3
record adds no second implementation. Accepting it does not apply the hardening
or establish release upload, OIDC login, registry publishing or installed-artifact
safety. Review the actual proposal and bounded evidence in #2409. No workflow,
installer, model, native app or release command was executed for this disposition.
