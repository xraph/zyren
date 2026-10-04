# Physical materials

Use `PhysicalMaterial` when you need clearcoat, sheen, anisotropy, thin films or
transmission. Its base surface keeps the standard material's metal/roughness maps,
linear data textures and sRGB color textures. glTF factors still multiply their
mapped channels. A zero factor disables the corresponding optional lobe.

The native shader specializes inactive lobes through pipeline constants. It also
prepares view-dependent GGX, coat and sheen terms once before the punctual-light
loop. A material with a metallic factor of one can still transmit when its
metallic map lowers the sampled value, so that combination keeps transmission.

You can use up to 512 distinct built-in pipelines and 128 physical-map binding
layouts in one frame. The renderer checks the combined scene, outline and
transmission passes before it changes the cache. It retires unused variants when
subsequent frames exceed the cache capacity, including retained bind groups that
refer to retired layouts. An oversized working set returns a descriptive error;
you can retry with a smaller set without losing the previous useful pipelines.
These bounds can reject unusually diverse scenes that an unbounded cache accepted.

Native readback tests compare mapped PBR batches with separately ordered draws.
The coverage includes explicit tangent handedness, nonuniform scale and mixed
transform determinant signs. These fixtures verify material behavior and cache
handling. They do not measure foreground frame rate.
