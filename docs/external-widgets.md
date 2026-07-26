# External widgets

External widget installation and execution are disabled.

The previous implementation copied executable bundles from arbitrary HTTPS
URLs or the local filesystem into a user-writable directory, removed their
quarantine attributes, and loaded them into Docky's process. That required
disabling hardened-runtime protections and gave widget code all permissions
granted to Docky.

Docky now treats existing `.dockywidget` files as inert data:

- It does not download, install, parse, or execute them.
- It does not remove quarantine or other extended attributes.
- It preserves existing files and saved profile records.
- Settings can reveal or explicitly delete an existing bundle.

Re-enabling third-party widgets requires a new architecture with all of the
following properties:

1. A signed marketplace manifest with a required payload digest and stable
   widget identity.
2. Explicit consent before any installation.
3. Strict code-signature, nested-code, notarization, and Gatekeeper checks
   before installation and again before execution.
4. Atomic staging and replacement without stripping quarantine.
5. Execution in a least-privileged process with a narrow IPC contract, never
   in Docky's main process.

Until that design is implemented and independently reviewed, the loader stays
fail-closed.
