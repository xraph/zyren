# Studio interface study

Run the mock from `examples/studio` with your pinned Flutter SDK:

```sh
fvm flutter run -d macos -t lib/mock/main.dart --no-pub
```

You can orbit the native sample assembly, select and hide parts, edit sample
positions and materials, scrub an exploded pose, and try the agent proposal.
Changes last for this preview session. The existing editor stays at
`lib/main.dart`.

## IDE layout

The design follows a compact IDE workspace. Scene and Assets share the left
rail. Agent, Properties and Review share the right rail. Each tool window can
move to the left, right or bottom dock through its menu. You can also drag its
header onto another dock or rail, resize dock dividers and hide the window.
Only one tool window occupies each dock at a time.

```text
Zyren Studio    Drive assembly                         Settings  Save
rail | Scene       | drive.zyren                  | Agent     | rail
     | Filter      | compact transform toolbar   | context   |
     | Assembly    |                             | proposal  |
     |  Parts      |       Native viewport       | changes   |
     |             |                             | Apply     |
     |             | Animation / scrubber        | prompt    |
Local preview                                           Native
```

Choose System, Light or Dark in Settings. System follows your OS appearance.
Light mode uses chrome `#EDF0F3`, panels `#FFFFFF`, borders `#D7DCE3`, text
`#242832`, muted text `#626A78` and accent `#315FBD`. Dark mode uses chrome
`#1E1F22`, panels `#25262A`, borders `#34363B`, text `#DFE1E5`, muted text
`#9299A5` and accent `#8AA8FF`. The native viewport keeps its slate background
so switching themes does not change the scene lighting or materials.

The platform sans-serif uses 11 to 12 px working text and 10 px supporting labels.
Flat sections, small icons and one document header keep the canvas visible.
The phone preview button in the right rail shows the narrow layout, where tool
windows use the bottom dock. Switching themes preserves your scene and docks.

## Built-in agent and settings

Studio supplies the agent workspace, selected-object context and proposal review.
You configure its LLM in Settings. The mock shows provider selection, a model ID,
base URL and a masked API key field. Provider choices are OpenAI-compatible,
Anthropic and Local model. These are design options, not connected adapters.

Save preview profile validates the model ID and URL, then updates the model label
in the Agent dock. The profile stays in memory for this session and is marked
Unverified. Keys are discarded when Settings closes. No network request is sent,
no credentials are persisted, and no connection test is simulated. Appearance
changes take effect immediately, including when you close without saving a profile.

Try example opens a sample conversation with three explicit position changes.
Apply updates the native sample scene; Undo restores the assembled pose. Discard
clears the proposal. Typed prompts reuse the example response. The composer stays
out of the setup view so you can see configuration actions in a narrow dock.

The existing agent registry exposes scene tools. Connecting an LLM, streaming
responses, secure credential storage and persistent settings belong to the next
implementation step, after you review this interface.

The sample drive assembly is generated locally through the native Zyren runtime.
It has no imported CAD provenance or engineering approval. Save and asset import
show where those commands belong without writing files. Tool-mode buttons show
selection states; transform gizmo behavior remains in the existing editor.

The shared Flutter `ZeroState` handles empty search results and agent setup. No walkthrough is
registered or exposed in this separate mock.

## Review checks

The macOS debug build, scoped Dart analysis and package-boundary checks pass.
The native mock was reviewed at desktop and 396 logical pixels. Agent Apply and
Undo update the sample pose; moving Agent to the bottom and back to the right
works without the composer overflow found during review. Header drag docking
and divider resizing are implemented, with manual gesture qualification still
pending. Production editor integration remains a separate step after you review
the design.

Light and dark appearance, required model/URL validation, saving and reopening a
sample profile, and the 396-pixel Settings layout were reviewed in the native
macOS app. The LLM connection remains unimplemented in this UI mock.
