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
Zyren Studio    Drive assembly                         UI mock  Save
rail | Scene       | drive.zyren                  | Agent     | rail
     | Filter      | compact transform toolbar   | context   |
     | Assembly    |                             | proposal  |
     |  Parts      |       Native viewport       | changes   |
     |             |                             | Apply     |
     |             | Animation / scrubber        | prompt    |
Local preview                                           Native
```

Tokens: chrome `#1E1F22`, panels `#25262A`, borders `#34363B`, text `#DFE1E5`,
muted text `#9299A5`, selection accent `#8AA8FF`. The platform sans-serif uses
11–12 px working text and 10 px supporting labels. Flat sections, small icons
and one document header keep the canvas visible. A phone preview button in the
right rail lets you inspect the narrow layout, where tool windows use the bottom
dock.

The agent panel shows selected-object context and a sample request. Its proposal
lists three explicit position changes. Apply updates the native sample scene;
Undo restores the assembled pose. Discard clears the proposal. The conversation
is a UI fixture with no connected model. Typed prompts demonstrate composer
layout and reuse the example proposal; they do not invoke an agent.

The sample drive assembly is generated locally through the native Zyren runtime.
It has no imported CAD provenance or engineering approval. Save and asset import
show where those commands belong without writing files. Tool-mode buttons show
selection states; transform gizmo behavior remains in the existing editor.

The shared Flutter `ZeroState` handles empty search results. No walkthrough is
registered or exposed in this separate mock.

## Review checks

The macOS debug build, scoped Dart analysis and package-boundary checks pass.
The native mock was reviewed at desktop and 396 logical pixels. Agent Apply and
Undo update the sample pose; moving Agent to the bottom and back to the right
works without the composer overflow found during review. Header drag docking
and divider resizing are implemented, with manual gesture qualification still
pending. Production editor integration remains a separate step after you review
the design.
