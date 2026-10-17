# iclean Constitution

## Core Principles

### I. Local-Only Data (NON-NEGOTIABLE)

All user data, derived data, and application state MUST be stored and processed only on
the user's own device.

- No data is uploaded, synced, mirrored, or backed up to any cloud service or remote server.
- No feature may require an account, login, or remote service to work.
- This applies equally to files, metadata, settings, logs, caches, and analysis results.

Rationale: the core promise of iclean is that nothing gets to the cloud. Every other
principle exists to keep that promise.

### II. No Outbound Network at Runtime

The application MUST work fully offline and MUST NOT open outbound network connections
during normal operation.

- No telemetry, analytics, usage tracking, or crash reporting to remote endpoints.
- No remote configuration, feature flags, or license checks.
- No cloud AI/LLM or other hosted APIs; any processing such as classification or search
  runs on-device.
- If a network feature is ever proposed, it requires a constitution amendment first
  (see Governance). It is never added by default.

Rationale: network access that does not exist cannot leak data.

### III. Offline-Safe Dependencies

Every third-party library, framework, or SDK MUST be vetted to confirm it does not contact
remote services at runtime.

- Dependencies that bundle analytics, crash reporting, or "phone home" behavior are
  rejected, or that behavior is provably disabled at build time.
- Downloading packages at development and build time is allowed; runtime behavior is what
  this principle governs.
- Each new dependency's network behavior is noted in the plan that introduces it.

Rationale: most privacy leaks come from dependencies, not first-party code.

### IV. User Owns Their Data

Users MUST be able to see, control, and remove everything iclean stores.

- All app data lives in documented local locations.
- Users can export their data in an open, readable format and delete it completely.
- Destructive operations, such as deleting or cleaning files, require explicit user
  confirmation and MUST NOT happen silently.

Rationale: local-only means nothing if the user cannot inspect or remove what is kept.

### V. Verifiable Privacy

The local-only guarantee MUST be checkable, not just promised.

- Automated tests or checks assert that core flows make no network calls (for example by
  running with networking blocked or by mocking and asserting zero requests).
- Code review rejects any new networking API usage, URL endpoint, or cloud SDK unless an
  amendment authorizes it.
- Network-related entitlements and permissions are not requested.

Rationale: a privacy guarantee that cannot be tested decays as the code grows.

## Data Handling Constraints

- Sensitive data at rest uses the platform's local protection (for example OS keychain,
  file protection, or disk encryption) where available.
- Logs stay on-device, contain no file contents or personal data beyond what debugging
  strictly needs, and are user-deletable.
- Temporary files are cleaned up after use.
- Platform cloud features (for example iCloud sync or cloud backup of app containers) are
  opted out of wherever the platform allows.

## Development Workflow & Quality Gates

- Every spec and plan includes a "Data & Network" check stating what data the feature
  touches, where it is stored, and confirming zero network access.
- Plans that add a dependency list its network behavior per Principle III.
- A change fails review if it adds network calls, remote endpoints, cloud SDKs, or
  telemetry, or if it stores data outside documented local locations.
- The privacy checks from Principle V must pass before merge.

## Governance

This constitution takes precedence over all other practices, specs, and plans in this
repository. Any conflict is resolved in favor of the constitution.

- Amendments are made by editing this file, with the reason recorded in the commit
  message and the Sync Impact Report.
- Any amendment that weakens Principle I or II is a MAJOR version change and must state
  exactly what data may leave the device, where it goes, and why.
- Versioning follows semantic versioning: MAJOR for removing or redefining principles,
  MINOR for new principles or sections or materially expanded guidance, PATCH for
  clarifications and wording.
- Every spec, plan, and review checks compliance with these principles; any complexity or
  exception must be justified in writing.

**Version**: 1.0.0 | **Ratified**: 2026-10-11 | **Last Amended**: 2026-10-11
