package dev.zyren.xr

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import com.google.ar.core.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.PlatformViewRegistry
import java.util.UUID
import java.util.concurrent.Executors

internal class XrFailure(val code: String, override val message: String) : RuntimeException(message)
internal fun requireXr(condition: Boolean, code: String, message: String) { if (!condition) throw XrFailure(code, message) }
internal fun Pose.values(): List<Double> = FloatArray(16).also { toMatrix(it, 0) }.map { it.toDouble() }

class ZyrenXrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, Application.ActivityLifecycleCallbacks {
    companion object { private var owner: ZyrenXrPlugin? = null; private const val permissionRequest = 61429 }
    private val main = Handler(Looper.getMainLooper())
    internal val worker = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    @Volatile private var activity: Activity? = null
    @Volatile private var active = false
    private val epochs = XrEpochs()
    private var runningEpoch = -1L
    private val frameClock = XrFrameClock()
    private val permissionStart = XrPermissionRequest<Pair<Map<String, Any?>, MethodChannel.Result>>()
    private var installRequested = false
    private var permissionRequested = false
    // Everything below is confined to worker, including ARCore and GPU ownership.
    private var session: Session? = null
    @Volatile private var sessionId: String? = null
    private var state = "ready"
    private var revision = 0
    private var originEpoch = 0
    private var depthEnabled = false
    private var frame: Frame? = null
    private var frameReceived = 0L
    private var failure: Map<String, Any?>? = null
    private val anchors = linkedMapOf<String, Anchor>()
    private val planes = linkedMapOf<Plane, String>()
    internal var presenter: XrVulkanPresenter? = null
    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "dev.zyren.xr/session.v1")
        channel.setMethodCallHandler(this)
        b.platformViewRegistry.registerViewFactory("dev.zyren.xr/vulkan.v1", XrViewFactory(this))
    }
    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        cancelStart()
        detachActivity()
        worker.execute { close(); main.post { if (owner === this) owner = null } }
        worker.shutdown()
    }
    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b; activity = b.activity; active = true
        b.addRequestPermissionsResultListener(this)
        b.activity.application.registerActivityLifecycleCallbacks(this)
    }
    private fun detachActivity() {
        epochs.invalidate(); active = false; cancelStart()
        binding?.removeRequestPermissionsResultListener(this)
        activity?.application?.unregisterActivityLifecycleCallbacks(this)
        binding = null; activity = null
        if (!worker.isShutdown) worker.execute { pause() }
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)
    override fun onActivityPaused(a: Activity) {
        if (a === activity) {
            epochs.invalidate(); active = false
            // Our permission dialog pauses the activity without stopping it.
            worker.execute { pause() }
        }
    }
    override fun onActivityResumed(a: Activity) {
        if (a === activity) {
            active = true
            permissionStart.resume()?.let { beginStart(it.first, it.second) }
        }
    }
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityStopped(a: Activity) { if (a === activity) cancelStart() }
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}
    private fun cancelStart() { permissionStart.cancel()?.second?.error("cancelled", "Session start was cancelled by the activity lifecycle.", null) }
    private fun permission(): String = if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) "authorized" else if (permissionRequested || context.getSharedPreferences("zyren_xr", Context.MODE_PRIVATE).getBoolean("cameraRequested", false)) "denied" else "notDetermined"
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grants: IntArray): Boolean {
        if (requestCode != permissionRequest) return false
        val authorized = permission() == "authorized"
        val pending = permissionStart.resolve(authorized, active) ?: return true
        if (!authorized) pending.second.error("permissionDenied", "Camera access was denied. Allow Camera in app settings or retry.", null)
        else beginStart(pending.first, pending.second)
        return true
    }
    private fun submit(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try { val value = operation(); main.post { result.success(value) } }
            catch (e: Exception) {
                val code = (e as? XrFailure)?.code ?: when (e) {
                    is com.google.ar.core.exceptions.CameraNotAvailableException -> "cameraUnavailable"
                    is com.google.ar.core.exceptions.NotYetAvailableException -> "frameDeferred"
                    is com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException -> "installDeclined"
                    is com.google.ar.core.exceptions.UnavailableApkTooOldException -> "servicesUpdateRequired"
                    is com.google.ar.core.exceptions.UnavailableSdkTooOldException -> "sdkUpdateRequired"
                    is com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException -> "unsupportedHardware"
                    is com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException -> "servicesNotInstalled"
                    is com.google.ar.core.exceptions.UnsupportedConfigurationException -> "unsupportedFeature"
                    else -> "nativeFailure"
                }
                if (code == "cameraUnavailable") {
                    pause(); state = "interrupted"
                    failure = mapOf("code" to code, "message" to (e.message ?: "Camera unavailable"))
                }
                main.post { result.error(code, e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }
    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<String, Any?> ?: emptyMap()
        if (call.method == "start") { beginStart(args, result); return }
        if (call.method == "create") {
            if (owner != null) { result.error("busy", "Another XR session owns the camera.", null); return }
            owner = this
        }
        if (call.method == "dispose" || call.method == "pause") { epochs.invalidate(); cancelStart() }
        submit(result) {
            when (call.method) {
                "capabilities" -> capabilities()
                "create" -> {
                    requireXr(sessionId == null, "busy", "An XR session already exists.")
                    sessionId = UUID.randomUUID().toString(); state = "ready"; revision = 0; originEpoch = 0
                    mapOf("sessionId" to sessionId)
                }
                "dispose" -> { if (sessionId != null) checkSession(args); close(); main.post { if (owner === this) owner = null }; null }
                else -> { checkSession(args); dispatch(call.method, args) }
            }
        }
    }
    private fun capabilities(): Map<String, Any?> {
        val availability = ArCoreApk.getInstance().checkAvailability(context)
        val supported = availability.isSupported
        return mapOf("platform" to "arcore", "availability" to availability.name,
            "worldTracking" to supported, "planeDetection" to supported, "anchors" to supported,
            "lightEstimation" to supported, "sceneDepthHardware" to (session?.isDepthModeSupported(Config.DepthMode.AUTOMATIC) ?: false),
            "cameraPresentation" to (presenter?.available == true), "depthOcclusion" to (presenter?.available == true && session?.isDepthModeSupported(Config.DepthMode.AUTOMATIC) == true), "cameraPermission" to permission())
    }
    private fun checkSession(args: Map<String, Any?>) { requireXr(args["sessionId"] == sessionId && sessionId != null, "invalidSession", "The XR session was released or replaced.") }
    private fun checkRevision(args: Map<String, Any?>) { requireXr((args["expectedRevision"] as? Number)?.toInt() == revision, "staleRevision", "The session changed before this action.") }
    private fun beginStart(args: Map<String, Any?>, result: MethodChannel.Result) {
        if (args["sessionId"] != sessionId || sessionId == null) { result.error("invalidSession", "The XR session has been released.", null); return }
        val a = activity
        if (a == null || !active) { result.error("appInactive", "Start XR from an active activity.", null); return }
        if (permissionStart.pending) { result.error("busy", "A camera permission request is pending.", null); return }
        try {
            if (ArCoreApk.getInstance().requestInstall(a, !installRequested) == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                installRequested = true; result.error("installRequested", "Complete Google Play Services for AR installation, then retry.", null); return
            }
        } catch (e: Exception) {
            val code = when (e) {
                is com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException -> { installRequested = false; "installDeclined" }
                is com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException -> "unsupportedHardware"
                is com.google.ar.core.exceptions.UnavailableApkTooOldException -> "servicesUpdateRequired"
                is com.google.ar.core.exceptions.UnavailableSdkTooOldException -> "sdkUpdateRequired"
                else -> "installUnavailable"
            }
            result.error(code, e.message, null); return
        }
        if (permission() != "authorized") {
            permissionStart.begin(args to result); permissionRequested = true
            context.getSharedPreferences("zyren_xr", Context.MODE_PRIVATE).edit().putBoolean("cameraRequested", true).apply()
            a.requestPermissions(arrayOf(Manifest.permission.CAMERA), permissionRequest); return
        }
        val startEpoch = epochs.lifecycle()
        submit(result) {
            checkSession(args)
            requireXr(active && epochs.current(startEpoch), "appInactive", "The activity left the foreground.")
            val required = listOf("horizontalPlanes", "verticalPlanes", "lightEstimation", "requireCameraPresentation", "requireDepthOcclusion", "resetTracking")
            requireXr(required.all { args[it] is Boolean }, "invalidArguments", "Session configuration is incomplete.")
            requireXr(state != "running" || args["resetTracking"] == true, "invalidState", "Pause before reconfiguring or reset tracking.")
            pause()
            if (args["resetTracking"] == true) {
                anchors.values.forEach { it.detach() }; anchors.clear(); planes.clear(); session?.close(); session = null; originEpoch++
            }
            val s = session ?: Session(context).also { session = it }
            depthEnabled = args["requireDepthOcclusion"] == true
            requireXr(!depthEnabled || s.isDepthModeSupported(Config.DepthMode.AUTOMATIC), "unsupportedFeature", "This device has no ARCore depth.")
            val configuration = Config(s).apply {
                depthMode = if (depthEnabled) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
                textureUpdateMode = Config.TextureUpdateMode.EXPOSE_HARDWARE_BUFFER
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                planeFindingMode = when {
                    args["horizontalPlanes"] == true && args["verticalPlanes"] == true -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                    args["horizontalPlanes"] == true -> Config.PlaneFindingMode.HORIZONTAL
                    args["verticalPlanes"] == true -> Config.PlaneFindingMode.VERTICAL
                    else -> Config.PlaneFindingMode.DISABLED
                }
                lightEstimationMode = if (args["lightEstimation"] == true) Config.LightEstimationMode.AMBIENT_INTENSITY else Config.LightEstimationMode.DISABLED
            }
            s.configure(configuration); s.resume(); runningEpoch = startEpoch; state = "running"; frame = null; revision++; failure = null
            if (!epochs.current(startEpoch)) { pause(); throw XrFailure("appInactive", "The activity changed during session start.") }
            null
        }
    }
    private fun pause() {
        presenter?.revoke(); frame = null
        if (state == "running") session?.pause()
        if (sessionId != null) { state = "paused"; revision++ }
    }
    private fun close() {
        pause(); presenter?.close(); presenter = null; epochs.register(null)
        anchors.values.forEach { it.detach() }; anchors.clear(); planes.clear()
        session?.close(); session = null; sessionId = null; failure = null
    }
    private fun update(): Frame {
        requireXr(state == "running" && active && epochs.current(runningEpoch), "trackingUnavailable", "The camera session is paused.")
        val p = presenter
        if (p?.hasLease == true) {
            requireXr(SystemClock.elapsedRealtimeNanos()-frameReceived < 500_000_000L, "trackingUnavailable", "The retained camera frame is stale.")
            return frame ?: throw XrFailure("trackingUnavailable", "No retained camera frame.")
        }
        p?.let { session!!.setDisplayGeometry(it.rotation, it.width.coerceAtLeast(1), it.height.coerceAtLeast(1)) }
        val f = session!!.update()
        frameReceived = frameClock.observe(f.timestamp, SystemClock.elapsedRealtimeNanos())
        frame = f
        requireXr(f.timestamp != 0L && SystemClock.elapsedRealtimeNanos() - frameReceived < 500_000_000L, "trackingUnavailable", "No fresh camera frame is available.")
        return f
    }
    private fun fresh(): Frame = update().also { requireXr(it.camera.trackingState == TrackingState.TRACKING, "trackingUnavailable", "The action requires normal tracking.") }
    private fun dispatch(method: String, args: Map<String, Any?>): Any? {
        when (method) {
            "pause" -> { pause(); return null }
            "snapshot" -> return snapshot()
            "createPresenter" -> {
                requireXr(presenter == null, "busy", "A presenter already exists.")
                val p = XrVulkanPresenter((args["runtime"] as? Number)?.toLong() ?: throw XrFailure("invalidArguments", "Runtime token is required."))
                presenter = p; epochs.register(p.id); return mapOf("presenterId" to p.id)
            }
            "addAnchor" -> return epochs.guarded(runningEpoch) {
                checkRevision(args); fresh()
                if (args.containsKey("expectedPresenterId") || args.containsKey("expectedPresentationEpoch")) {
                    val p = presenter
                    requireXr(p != null && args["expectedPresenterId"] == p.id && p.matchesEpoch(args["expectedPresentationEpoch"], epochs.surface()), "staleFrame", "The presented viewport changed before placement.")
                }
                (args["expectedFrameTimestamp"] as? Number)?.toDouble()?.let { requireXr(it.isFinite() && it <= frameReceived / 1e9 && frameReceived / 1e9 - it < 0.5, "staleFrame", "Placement frame is stale.") }
                requireXr(anchors.size < 128, "anchorLimit", "Remove an anchor before adding another.")
                val pose = XrGeometry.pose(args["transform"])
                val anchor = session!!.createAnchor(pose); val id = UUID.randomUUID().toString(); anchors[id] = anchor
                presenter?.revoke(); revision++; mapOf("anchorId" to id)
            }
            "removeAnchor" -> {
                checkRevision(args); val anchor = anchors.remove(args["anchorId"]) ?: throw XrFailure("unknownAnchor", "Anchor is not part of this session.")
                anchor.detach(); presenter?.revoke(); revision++; return null
            }
            "planeGeometry" -> { checkRevision(args); fresh(); val plane = planes.entries.firstOrNull { it.value == args["planeId"] }?.key ?: throw XrFailure("unknownPlane", "The plane is no longer available."); return XrGeometry.geometry(plane, args["planeId"] as String, revision, frameReceived / 1e9) }
        }
        val p = presenter ?: throw XrFailure("invalidPresenter", "Create a presenter first.")
        requireXr(args["presenterId"] == p.id, "invalidPresenter", "The presenter has been released.")
        return when (method) {
            "closePresenter" -> { p.close(); presenter = null; epochs.register(null); null }
            "acquireFrame" -> p.acquire(update().also { requireXr(!depthEnabled || SystemClock.elapsedRealtimeNanos()-frameReceived <=250_000_000L,"staleDepth","Depth frame is older than 250 milliseconds.") }, revision, (args["near"] as? Number)?.toDouble() ?: 0.01, (args["far"] as? Number)?.toDouble() ?: 1000.0, depthEnabled, frameReceived).also { if (!epochs.current(runningEpoch)) { p.cancel(); throw XrFailure("frameDeferred", "The activity changed during acquisition.") } }
            "cancelFrame" -> { p.cancel((args["frameId"] as Number).toInt()); null }
            "presentFrame" -> p.present(args, revision,
                { active && state == "running" && epochs.current(runningEpoch) && p.generation == epochs.surface() },
                { publish -> epochs.guarded(runningEpoch) {
                    requireXr(active && p.generation == epochs.surface(), "frameDeferred", "The presented viewport changed.")
                    publish()
                } })
            "gpuCommand" -> p.command(args)
            "raycast" -> { checkRevision(args); val f = fresh(); XrGeometry.raycast(f, p, args, revision, originEpoch, frameReceived / 1e9, ::planeId) }
            else -> throw XrFailure("unsupportedMethod", "Unknown XR operation: $method")
        }
    }
    private fun planeId(p: Plane): String = planes.getOrPut(p) { UUID.randomUUID().toString() }
    private fun snapshot(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>("sessionId" to sessionId, "state" to state, "revision" to revision,
            "originEpoch" to originEpoch, "nativeTimestamp" to SystemClock.elapsedRealtimeNanos() / 1e9)
        failure?.let { out["failure"] = it }
        if (state != "running") return out
        val f = try { update() } catch (e: XrFailure) { if (e.code == "trackingUnavailable") return out else throw e }
        val c = f.camera; val intrinsics = c.imageIntrinsics; val focal = intrinsics.focalLength; val center = intrinsics.principalPoint
        val available = session!!.getAllTrackables(Plane::class.java).filter { it.trackingState == TrackingState.TRACKING && it.subsumedBy == null }
        planes.keys.retainAll(available.toSet())
        val value = mutableMapOf<String, Any?>("timestamp" to frameReceived / 1e9, "sensorTimestamp" to f.timestamp / 1e9, "cameraTransform" to c.pose.values(),
            "tracking" to if (c.trackingState == TrackingState.TRACKING) "normal" else if (c.trackingState == TrackingState.PAUSED) "limited" else "unavailable",
            "trackingReason" to c.trackingFailureReason.name.lowercase(),
            "intrinsics" to listOf(focal[0].toDouble(), 0.0, 0.0, 0.0, focal[1].toDouble(), 0.0, center[0].toDouble(), center[1].toDouble(), 1.0),
            "imageWidth" to intrinsics.imageDimensions[0], "imageHeight" to intrinsics.imageDimensions[1],
            "anchors" to anchors.filterValues { it.trackingState != TrackingState.STOPPED }.map { (id, a) -> mapOf("id" to id, "tracking" to if (a.trackingState == TrackingState.TRACKING) "normal" else "limited", "transform" to a.pose.values()) },
            "planes" to available.take(128).map { p -> mapOf("id" to planeId(p), "transform" to p.centerPose.values(), "alignment" to if (p.type == Plane.Type.VERTICAL) "vertical" else "horizontal", "center" to listOf(0.0,0.0,0.0), "extent" to listOf(p.extentX.toDouble(),0.0,p.extentZ.toDouble())) },
            "omittedPlanes" to (available.size - 128).coerceAtLeast(0))
        if (f.lightEstimate.state == LightEstimate.State.VALID) value["light"] = mapOf("ambientIntensity" to f.lightEstimate.pixelIntensity.toDouble(), "colorTemperature" to null, "intensityUnit" to "relative-gamma", "colorCorrection" to FloatArray(4).also { f.lightEstimate.getColorCorrection(it, 0) }.map { it.toDouble() })
        out["nativeTimestamp"] = SystemClock.elapsedRealtimeNanos() / 1e9
        out["frame"] = value; return out
    }
    internal fun surface(id: String, surface: Surface?, width: Int, height: Int, density: Float, rotation: Int) {
        @Suppress("DEPRECATION")
        val displayRotation = activity?.windowManager?.defaultDisplay?.rotation ?: rotation
        val generation = epochs.changeSurface(id) ?: return
        worker.execute { try { presenter?.takeIf { it.id == id }?.surface(surface, width, height, density, displayRotation, generation) } catch (e: Exception) { failure = mapOf("code" to "surfaceUnavailable", "message" to (e.message ?: "Camera surface unavailable")); pause() } }
    }
}
