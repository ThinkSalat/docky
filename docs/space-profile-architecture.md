# Space profile architecture

Docky treats a Mission Control Space assignment as a small ownership record,
not as profile content. Assigning, reassigning, repairing, or removing a Space
must never copy, rename, clear, or otherwise mutate either profile's layout.

## Prior art and platform constraints

- Apple's `NSWorkspace.activeSpaceDidChangeNotification` documentation says:
  “The notification doesn’t contain a userInfo dictionary.” Docky therefore
  treats it as an invalidation signal and re-reads topology instead of deriving
  identity from the callback.
  <https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification>
- Apple exposes an option to “Automatically rearrange Spaces based on most
  recent use.” Positional Desktop numbers are presentation metadata, not
  durable identity.
  <https://support.apple.com/en-gb/guide/mac-help/mchlp1119/mac>
- Hammerspoon's Space watcher warns: “You should not depend on Space numbers
  being around forever!” Docky never persists a numeric SkyLight Space ID.
  <https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces_watcher.m#L6-L10>
- AeroSpace warns: “You shouldn't rely on the order callbacks are called.”
  Docky serializes every app, time, display, and Space signal through the same
  topology reconciler.
  <https://github.com/nikitabobko/AeroSpace/blob/d56e1637c3a1ed660d0cadd7534e94fb3218d1c3/docs/guide.adoc#L624-L640>
- yabai obtains a Space's persistent name with `SLSSpaceCopyName`, stores that
  separately from the volatile numeric ID, then re-targets the numeric ID after
  topology changes. Docky uses the same identity/observation split.
  <https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L166-L175>
  <https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/view.c#L907-L917>
  <https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1056-L1103>
- yabai introduced name/UUID rebinding specifically to preserve Space layouts
  when volatile IDs changed after sleep/display reconnection. This is strong
  operating prior art, not an Apple guarantee: every API involved is private.
  <https://github.com/asmvik/yabai/commit/30f3102ac6b94b5ba5df40914301f18e274953da>
- Docky's last user-confirmed low-latency engine (`f8226b3`) evaluated an
  exact numeric-Space rule directly from the active-Space notification. The
  current engine preserves that immediate-arrival behavior while replacing the
  volatile numeric rule with yabai's persistent-name primitive and an assignment
  confirmed in the on-disk profile document.

## Identity

- A non-empty SkyLight Space name/UUID is the durable key. It remains the same
  when Mission Control reorders the Space or moves it to another display.
- The root Desktop has an empty SkyLight name. Its key is therefore scoped to
  the physical display when displays have separate Spaces, or to one shared
  display scope otherwise.
- Numeric Space IDs, display order, and Desktop ordinals are observations used
  only for reconciliation, diagnostics, and labels.
- Fullscreen/tiled Spaces are not assignable. They may use generic
  app-on-Space rules.

## Reconciliation

Every signal invalidates cached settled Space state. Docky publishes a settled
target only after three identical samples spanning at least 0.5 seconds. It
rejects malformed display dictionaries, duplicate target-display records,
membership conflicts, UUID/name conflicts, type conflicts, display mismatches,
animation-period samples, and backwards monotonic time.

One deliberately narrower lane restores immediate profile switching for a
known assigned Desktop. It reads the target display's current numeric ID only
to call `SLSSpaceCopyName`, then matches that persistent name directly against
the saved assignment while settlement continues in the background. It runs at
startup, on Space/display lifecycle signals, on watchdog-detected crossings,
and on the early reconciliation samples. A transiently incomplete first read
does not consume the arrival; a resolved name is retried before the
half-second settled-state gate.

The owner must come from the last profile document that actually reached disk;
persistence must not be blocked; and this Space's current owner and target
profile contents must still equal their durable values. Whole-document
revision equality is intentionally not required, so an unrelated pending edit
cannot slow every assigned Space. The lane is disabled for a new or unassigned
Desktop, a pending edit to this assignment or target profile, fullscreen or
unresolved state, assignment verification, manual binding, and a conflicting
manual override. Only a successful activation consumes an arrival.

The target display is captured once. Generic-rule evidence is published only
after the sequence `Space S1 → frontmost F1 → windows → frontmost F2 → Space
S2` proves `S1 == S2` and `F1 == F2` on that same physical display. Exact
ownership never waits for unrelated window/frontmost-app evidence.
Notification payloads are wake-up signals; callback order never supplies an
identity. App and minute intent is sticky for the unsettled reconciliation
epoch, so a later topology callback cannot erase it. Manual binding and
assignment verification are stronger observation-only intents and cannot be
demoted into automation. The fact that an epoch crossed into a new target also
survives a rejected evidence bracket, so a retry cannot reinterpret arrival as
a later same-Desktop event.

A regular Desktop whose durable identity is temporarily missing is unresolved,
not unassigned. It cannot run exact or generic rules until coherent identity
returns.

## New and unassigned Desktops

Arriving on a newly-created or unassigned regular Desktop preserves the layout
already visible. Docky does not guess an owner and does not create an
assignment. A later, independently revalidated frontmost-app or time event may
run the user's generic rule without claiming the Desktop.

Exact ownership is created only by an explicit, confirmed assignment. The
Desktop identity and previous owner are read before the confirmation and read
again afterward; any change aborts the operation.

While that fresh assignment verification owns the sampler, app and minute
signals are coalesced and deferred until it finishes. They cannot abort an
otherwise-stable verification, while a real topology or display-target change
still aborts it. Verification is a token-owned observation overlay rather than
a persisted reconciliation reason: topology, manual-binding, app, and minute
intent remain queued underneath it. Only the matching token may release the
overlay. A timeout, cancellation, omitted macOS callback, or Space change
observed first by verification always resumes normal topology reconciliation.

Manual binding and automation use separate pending lanes. Committing the
manual observation cannot consume a topology, app, or minute event that
arrived beneath it; that event runs through a fresh evidence bracket
afterward.

Assignment edits do not switch the currently-visible dock. They take effect
when the Desktop is entered again or when Docky next starts. The assignment
owner is latched on entry for the entire confirmed residency, so a later app,
minute, or watchdog signal cannot observe a just-edited owner early.

Every explicit manual profile choice is initially unbound and forces a
post-click reconciliation. It binds only to the first coherent committed
residency, so a delayed Space callback cannot attach the choice to the origin
Desktop. Assignment verification and manual binding use typed observation-only
sampling modes that are forbidden from running automation.

## Persistence

Profile contents and the global one-owner-per-Space assignment table are one
versioned document. Every mutation validates a complete candidate before it is
accepted. Legacy binding repair changes ownership and removes the legacy row
in one document commit.

Automatic activation is runtime-only. It does not change the durable default,
increment the profile document revision, or rotate backups.

Writes use an interprocess lock, compare the on-disk primary with the actual
durable predecessor, and retain primary, backup, and previous-backup
generations. Schema migration archives both pre-migration generations.
Invalid primaries are quarantined before recovery.
