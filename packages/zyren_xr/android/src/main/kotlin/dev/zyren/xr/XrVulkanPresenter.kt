package dev.zyren.xr

import android.content.Context
import android.hardware.HardwareBuffer
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.UUID

internal object XrNative {
    init { System.loadLibrary("zyren_xr") }
    external fun create(token: Long): Long
    external fun destroy(handle: Long)
    external fun surface(handle: Long, surface: Surface?, width: Int, height: Int)
    external fun render(handle: Long, buffer: HardwareBuffer, uv: FloatArray, packet: ByteArray, depth: ByteArray?, depthWidth: Int, depthHeight: Int, depthCalibration: FloatArray?, depthDeadline: Long): Boolean
    external fun readback(handle: Long): Long
    external fun ready(handle: Long): Boolean
    external fun publish(handle: Long): Boolean
    external fun discard(handle: Long)
    external fun command(handle: Long, kind: Int, bytes: ByteArray, capacity: Int): ByteArray
}
internal class XrVulkanPresenter(token: Long) {
    val id = UUID.randomUUID().toString()
    private val native = XrNative.create(token)
    var width = 0; private set
    var height = 0; private set
    var rotation = 0; private set
    var generation = 0L; private set
    private var density = 1f
    private var epoch = 0
    private var nextFrame = 0
    private var presented = 0
    private var closed = false
    private var failed = false
    val available: Boolean get() = !closed && !failed
    private var buffer: HardwareBuffer? = null
    private var uv: FloatArray? = null
    private var depth: ByteArray? = null
    private var depthWidth = 0
    private var depthHeight = 0
    private var depthCalibration: FloatArray? = null
    private var observedNanos = 0L
    private var lease: Map<String, Any?>? = null
    var presentedCalibration: Map<String, Any?>? = null; private set
    val hasLease: Boolean get() = lease != null
    fun revoke() { cancel(); epoch++; presentedCalibration = null }
    fun surface(surface: Surface?, width: Int, height: Int, density: Float, rotation: Int, generation: Long) {
        if (closed) return
        revoke(); this.generation = generation; this.width = width; this.height = height; this.density = density; this.rotation = rotation
        XrNative.surface(native, surface, width, height)
    }
    fun requireSurfaceReady() {
        requireXr(width in 1..4096 && height in 1..4096 && XrNative.ready(native),
            "frameDeferred", "The camera surface dimensions are still changing.")
    }
    fun acquire(frame: Frame, revision: Int, near: Double, far: Double, depthEnabled: Boolean, observedNanos: Long): Map<String, Any?> {
        requireXr(available && !hasLease, "busy", "A camera frame is already retained.")
        requireXr(width in 1..4096 && height in 1..4096, "frameDeferred", "The camera surface is not attached at a supported size.")
        requireXr(near.isFinite() && far.isFinite() && near > 0 && far > near, "invalidArguments", "Invalid clipping range.")
        val projection = FloatArray(16); frame.camera.getProjectionMatrix(projection, 0, near.toFloat(), far.toFloat())
        // ARCore supplies OpenGL clip depth; Zyren uses native zero-to-one depth.
        for (column in 0..3) projection[column*4+2] = (projection[column*4+2]+projection[column*4+3])*.5f
        val coords = FloatArray(6)
        frame.transformCoordinates2d(Coordinates2d.VIEW_NORMALIZED, floatArrayOf(0f,0f,1f,0f,0f,1f), Coordinates2d.TEXTURE_NORMALIZED, coords)
        this.observedNanos = observedNanos
        var depthTimestamp: Double? = null
        var depthSensorTimestamp: Double? = null
        if (depthEnabled) {
            try {
                frame.acquireRawDepthImage16Bits().use { image ->
                    frame.acquireRawDepthConfidenceImage().use { confidence ->
                        requireXr(image.timestamp == frame.timestamp && confidence.timestamp == image.timestamp,
                            "staleDepth", "Raw depth must match the retained camera timestamp.")
                        requireXr(image.width in 1..2048 && image.height in 1..2048 && image.width == confidence.width && image.height == confidence.height,
                            "depthUnavailable", "Depth and confidence dimensions differ.")
                        depthWidth = image.width; depthHeight = image.height
                        val data = java.nio.ByteBuffer.allocate(depthWidth*depthHeight*4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                        val d = image.planes[0]; val c = confidence.planes[0]
                        val db = d.buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN); val cb = c.buffer
                        for (y in 0 until depthHeight) for (x in 0 until depthWidth) {
                            val mm = db.getShort(y*d.rowStride+x*d.pixelStride).toInt() and 65535
                            val quality = cb.get(y*c.rowStride+x*c.pixelStride).toInt() and 255
                            data.putInt(mm or (quality shl 16))
                        }
                        depth = data.array(); depthTimestamp = observedNanos/1e9; depthSensorTimestamp = image.timestamp/1e9
                        val mapping = FloatArray(6)
                        frame.transformCoordinates2d(Coordinates2d.VIEW_NORMALIZED,floatArrayOf(0f,0f,1f,0f,0f,1f),Coordinates2d.IMAGE_NORMALIZED,mapping)
                        depthCalibration = floatArrayOf(mapping[2]-mapping[0],mapping[4]-mapping[0],mapping[0],0f,
                            mapping[3]-mapping[1],mapping[5]-mapping[1],mapping[1],0f,projection[10],projection[14],projection[11],projection[15])
                    }
                }
            } catch (e: com.google.ar.core.exceptions.NotYetAvailableException) { throw XrFailure("depthUnavailable", "This camera frame has no raw depth and confidence.") }
        }
        // Frame.getHardwareBuffer returns an acquired Java owner. JNI acquires a
        // second native reference and releases it only after its GPU fence.
        buffer = frame.hardwareBuffer
        uv = coords
        val det = (coords[2]-coords[0])*(coords[5]-coords[1])-(coords[4]-coords[0])*(coords[3]-coords[1])
        requireXr(kotlin.math.abs(det) > 1e-6, "invalidCalibration", "Camera display transform is singular.")
        val a=(coords[5]-coords[1])/det; val b=-(coords[3]-coords[1])/det
        val c=-(coords[4]-coords[0])/det; val d=(coords[2]-coords[0])/det
        val calibration = mapOf<String, Any?>("frameId" to ++nextFrame, "timestamp" to observedNanos/1e9, "sensorTimestamp" to frame.timestamp/1e9,
            "revision" to revision, "epoch" to epoch, "projection" to projection.map { it.toDouble() },
            "cameraTransform" to frame.camera.displayOrientedPose.values(), "logicalWidth" to width/density.toDouble(),
            "logicalHeight" to height/density.toDouble(), "devicePixelRatio" to density.toDouble(),
            "pixelWidth" to width, "pixelHeight" to height, "orientation" to intArrayOf(1,3,2,4)[rotation], "near" to near, "far" to far,
            "depthEnabled" to depthEnabled, "depthTimestamp" to depthTimestamp, "depthSensorTimestamp" to depthSensorTimestamp,
            "displayTransform" to listOf(a.toDouble(), b.toDouble(), c.toDouble(), d.toDouble(), (-a*coords[0]-c*coords[1]).toDouble(),(-b*coords[0]-d*coords[1]).toDouble()))
        lease = calibration; return calibration
    }
    fun cancel(frameId: Int? = null) { if (frameId == null || lease?.get("frameId") == frameId) { buffer?.close(); buffer = null; uv = null; depth = null; depthCalibration = null; lease = null } }
    fun matchesEpoch(value: Any?, generation: Long): Boolean = !closed && width > 0 && height > 0 && value == epoch && this.generation == generation
    fun present(args: Map<String, Any?>, revision: Int, active: () -> Boolean, publish: (() -> Unit) -> Unit): Map<String, Any?> {
        val frame = lease
        requireXr(frame != null && args["frameId"] == frame["frameId"] && args["revision"] == revision && frame["revision"] == revision && active(), "frameDeferred", "The camera lease or session changed.")
        try {
            requireXr(depth == null || android.os.SystemClock.elapsedRealtimeNanos()-observedNanos <= 250_000_000L, "staleDepth", "The retained depth observation is older than 250 milliseconds.")
            val drawableReady = XrNative.render(native, buffer!!, uv!!, args["packet"] as? ByteArray ?: throw XrFailure("invalidArguments", "Scene packet is missing."), depth, depthWidth, depthHeight, depthCalibration, if (depth != null) observedNanos+250_000_000L else 0L)
            var nativePresented = false
            if (!drawableReady || !publishRenderedFrame(active, { publish { nativePresented = XrNative.publish(native) } }, { XrNative.discard(native) }) || !nativePresented) {
                return frame!! + mapOf("applied" to true, "presented" to false)
            }
            presented++; presentedCalibration = frame
            return frame!! + mapOf("applied" to true, "presented" to true, "cameraReadbackBytes" to 0L,
                "nativeReadbackBytes" to XrNative.readback(native), "depthUploadBytes" to (depth?.size ?: 0), "depthConfidenceMinimum" to 128, "inFlightLimit" to 1, "heldCameraFrames" to 0, "drawableLimit" to 2, "presentedFrames" to presented)
        } catch (e: IllegalStateException) { if (e.message?.startsWith("staleDepth:") == true) throw XrFailure("staleDepth", e.message!!); failed = true; throw e } finally { cancel() }
    }
    fun command(args: Map<String, Any?>): Map<String, Any?> {
        val kind = listOf("resource", "shader", "graph").indexOf(args["kind"])
        val bytes = args["bytes"] as? ByteArray ?: throw XrFailure("invalidArguments", "GPU command bytes are missing.")
        val capacity = (args["capacity"] as? Number)?.toInt() ?: 0
        requireXr(kind >= 0 && capacity in 1..(64*1024*1024+24), "invalidArguments", "Invalid GPU command capacity.")
        val out = XrNative.command(native, kind, bytes, capacity)
        val status = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN).int
        return if (status == 0) mapOf("status" to 0, "bytes" to out.copyOfRange(4,out.size)) else mapOf("status" to status, "message" to out.copyOfRange(4,out.size).toString(Charsets.UTF_8))
    }
    fun close() { if (!closed) { revoke(); XrNative.destroy(native); closed = true } }
}
internal class XrViewFactory(private val plugin: ZyrenXrPlugin): PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val id = (args as? Map<*, *>)?.get("presenterId") as? String ?: ""
        return object : PlatformView, SurfaceHolder.Callback, android.hardware.display.DisplayManager.DisplayListener {
            private val displays = context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
            private val view = SurfaceView(context).also {
                it.holder.addCallback(this)
                displays.registerDisplayListener(this, android.os.Handler(android.os.Looper.getMainLooper()))
            }
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
            override fun onDisplayChanged(id: Int) {
                if (id == android.view.Display.DEFAULT_DISPLAY && view.holder.surface.isValid) {
                    plugin.surface(objectId(), view.holder.surface, view.width, view.height, context.resources.displayMetrics.density, 0)
                }
            }
            private fun objectId() = id
            override fun getView() = view
            override fun dispose() { displays.unregisterDisplayListener(this); view.holder.removeCallback(this); plugin.surface(id, null, 0, 0, 1f, 0) }
            override fun surfaceCreated(holder: SurfaceHolder) {}
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { plugin.surface(id, holder.surface, width, height, context.resources.displayMetrics.density, view.display?.rotation ?: 0) }
            override fun surfaceDestroyed(holder: SurfaceHolder) { plugin.surface(id, null, 0, 0, 1f, 0) }
        }
    }
}
