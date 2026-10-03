# OpenXR headset adapter design

You will select a headset runtime independently of the mobile AR session.
ARKit and ARCore capability results must not advertise headset support. This
document defines the adapter boundary; no OpenXR backend is registered yet.

## Runtime and graphics selection

Use the Khronos loader for the host platform. Enumerate instance extensions,
create the instance with only required and supported optional extensions, then
select a system for the requested form factor. Report missing loader, missing
runtime, unavailable system and unsupported graphics binding separately.

The runtime chooses the graphics device. A renderer created on an arbitrary
device cannot safely import the runtime's swapchain textures. Add an explicit
native renderer constructor that adopts the runtime-selected device and queue
before creating scene resources. This is a shared renderer requirement, not an
XR policy in the Dart scene graph.

| Binding | Required selection and ownership |
| --- | --- |
| Metal | Enable `XR_KHR_metal_enable`, call `xrGetMetalGraphicsRequirementsKHR`, and create the session's command queue on its returned Metal device. |
| Vulkan | Use `XR_KHR_vulkan_enable2` requirements and runtime-assisted instance/device creation. Preserve the selected physical device, queue family and index when adopting it into the renderer. |
| DX12 | Use `XR_KHR_D3D12_enable` requirements and adapter identity to create the device and command queue. Submit only through the queue passed to the session. |

The Metal extension is ratified. Its existence does not establish availability
on a particular headset. Probe the runtime extension list before offering the
binding. See [Metal requirements](https://registry.khronos.org/OpenXR/specs/1.1/man/html/xrGetMetalGraphicsRequirementsKHR.html),
[Vulkan binding](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XR_KHR_vulkan_enable2.html)
and [DX12 binding](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XR_KHR_D3D12_enable.html).

## Session and frame ownership

One native render thread owns the session event loop and frame sequence. The
Dart host supplies bounded, immutable scene submissions. Flutter widget frames
do not drive headset timing.

Start a session only after the runtime reports READY. STOPPING drains GPU work
and ends the session. EXITING terminates it. LOSS_PENDING invalidates all frame,
space and action generations and requires recreation. Instance loss also
invalidates the graphics binding and dependent resources. Never treat lost
tracking as an identity pose.

For each frame, call `xrWaitFrame` once, preserve its predicted display time,
then call `xrBeginFrame`. Locate views and action spaces at that same time.
Capture one scene revision for both eyes. If `shouldRender` is false, finish
the frame without projection layers. The predicted time belongs to the runtime
clock and must not be replaced with a Dart wall-clock timestamp. See
[frame timing](https://registry.khronos.org/OpenXR/specs/1.1/man/html/xrWaitFrame.html).

Enumerate view configuration and formats. Allocate one swapchain per view in
the initial implementation, using each view's recommended dimensions and a
supported sample count. Acquire an image, wait for ownership, render its eye's
pose and asymmetric field of view, then release it under the binding's GPU
ordering rules. The runtime owns the images; Zyren must not destroy them.
Bound the application to one in-flight frame until the queue and compositor
handoff are qualified.

`XR_TIMEOUT_EXPIRED` from `xrWaitSwapchainImage` does not grant image access.
Retry the wait for that acquisition; do not write, release or advance to another
image as if the wait succeeded. Stop/resize paths must account for every acquired
image before destroying a swapchain. See
[swapchain image wait](https://registry.khronos.org/OpenXR/specs/1.1/man/html/xrWaitSwapchainImage.html).

## Spaces, input and agent access

Expose VIEW, LOCAL and available STAGE spaces as distinct identities. Maintain
a host-controlled scene-from-reference-space transform. Reference-space change
events advance its generation; old raycasts, anchors and commands become stale.
Application source IDs remain independent of session-local handles.

Create action sets before attachment. Use semantic actions for select, grip,
aim, navigation and haptics, with suggested bindings for detected interaction
profiles. Sync actions only while the session permits it. Expose inactive action
state explicitly. A focus loss releases captures and stops haptics; returning
focus does not replay a held command.

Register through `zyren_agents`. Each hit must carry its eye/view, predicted
display time, rendered scene revision, frame ID, space generation and source
identity where known. A CPU raycast describes geometric coverage. Exact rendered
pixel evidence requires a matching native query. Commands use the same host
tools as controller input, with scopes, expected revisions and retry keys.

## Acceptance before registration

The adapter stays unavailable until a named runtime and device pass lifecycle,
stereo alignment, asymmetric projection, eye order, resize, image timeout,
tracking loss, reference-space change, input focus and renderer-loss tests.
Record frame pacing, resource retirement and readback counters under load.
Exercise a permitted action and a denied action over the shared MCP transport.

Qualify each graphics binding separately. No headset runtime or physical
headset has been exercised by this workstream. The current native renderers
choose their own graphics devices, so runtime-device adoption and swapchain
imports remain implementation dependencies before a headset adapter can ship.
