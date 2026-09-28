# Planetary depth precision

You can opt a camera into reversed depth when the backend supports it. Standard
depth stays the default. Both modes use the same camera-relative world coordinates.

## Camera and frame contract

- Test perspective and orthographic endpoints, projection round trips, picking,
  immutable submissions and unsupported backend rejection.
- Add a public depth strategy and keep projection, clear, comparison and resolve
  under that one choice. Preserve the existing packet format for standard depth.
- Quantify float32 depth reconstruction at surface, horizon and orbit distances.

## Native rendering and effects

- Carry the strategy through native frame validation and pipeline keys.
- Reverse depth comparison and MSAA depth resolve together. Keep shadow maps in
  their own standard convention and adapt camera frustum extraction.
- Expose shared screen depth reconstruction helpers. Use them in atmosphere,
  including background detection and orthographic rays.
- Test occlusion, material paths, clipping, primitives, multisampling and effects
  on the native backend. Exercise the camera mode on a native Flutter surface.

## Evidence and review

- Run relevant Dart, Rust and native integration checks. Record measured error,
  tested devices and resource disposal. Review the final diff and commit it.
- Update the roadmap and parity gates to distinguish depth support from remote
  terrain, 3D Tiles and provider qualification, which remain separate work.
