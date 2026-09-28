package dev.twinos.zyren

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

internal object Native {
    init { System.loadLibrary("zyren_surface") }
    external fun connect(runtime: Long)
    external fun create(): Long
    external fun destroy(handle: Long)
    external fun detach(handle: Long)
    external fun render(handle: Long, surface: Surface, packet: ByteArray, width: Int, height: Int): Boolean
    external fun present(handle: Long)
    external fun info(handle: Long): String
    external fun counters(): LongArray
    external fun gpu(handle: Long, operation: Int, packet: ByteArray, capacity: Int): ByteArray
}

/** Controller-owned Vulkan renderers with replaceable Flutter surface attachments. */
class ZyrenPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var textures: TextureRegistry
    private val channels = mutableListOf<MethodChannel>()
    private val sessions = mutableMapOf<Long, Session>()
    private var nextId = 1L
    private var connected = false
    private var attached = false
    private var surfaceCount = 0
    private var presentedCount = 0L
    private var readbackBytes = 0L
    @Volatile private var testGate: PublicationGate? = null

    private class PublicationGate {
        val claimed = AtomicBoolean(false)
        val release = CountDownLatch(1)
        @Volatile var entered = false
        @Volatile var timedOut = false
        fun waitOnce() {
            if (!claimed.compareAndSet(false, true)) return
            entered = true
            timedOut = !release.await(10, TimeUnit.SECONDS)
            check(!timedOut) { "Publication test gate timed out." }
        }
    }

    private class Generation(val epoch: Long)

    private class Session(val id: Long) {
        var handle = 0L // Native worker only until creation completes.
        val generation = AtomicReference(Generation(1L))
        val epoch: Long get() = generation.get().epoch
        fun invalidate() { generation.updateAndGet { Generation(it.epoch + 1) } }
        @Volatile var closed = false
        @Volatile var available = true
        @Volatile var suspended = false
        @Volatile var failure: String? = null
        var producer: TextureRegistry.SurfaceProducer? = null
        var attachment = 0L
        var attachmentClosed = false
        var busy = false // Platform thread only.
        var surface: Surface? = null // Identity only; fetch producer.surface for every frame.
        var width = 1
        var height = 1
        var presentedFrame = 0L
        var readback = 0L
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        for (name in listOf("zyren/android-proof", "zyren/android-surfaces")) {
            channels.add(MethodChannel(binding.binaryMessenger, name).also { it.setMethodCallHandler(this) })
        }
        attached = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        if (BuildConfig.DEBUG) testGate?.release?.countDown()
        channels.forEach { it.setMethodCallHandler(null) }
        channels.clear()
        sessions.values.toList().forEach { close(it, null) }
        worker.shutdown()
    }

    private fun revoke(session: Session) {
        session.invalidate()
        session.surface = null
        session.presentedFrame = 0
        worker.execute {
            try { if (session.handle != 0L) Native.detach(session.handle) }
            catch (error: Exception) { session.failure = error.message ?: "Native detach failed." }
        }
    }

    private fun allocate(session: Session) {
        val producer = textures.createSurfaceProducer()
        surfaceCount++
        session.producer = producer
        session.available = true
        producer.setSize(session.width, session.height)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (!session.closed && session.producer === producer) { session.available = true; revoke(session) }
            }
            override fun onSurfaceCleanup() {
                if (!session.closed && session.producer === producer) { session.available = false; revoke(session) }
            }
        })
    }

    private fun release(producer: TextureRegistry.SurfaceProducer?) {
        if (producer != null) { producer.release(); surfaceCount-- }
    }

    private fun detach(session: Session, result: MethodChannel.Result) {
        session.attachmentClosed = true
        val producer = session.producer
        session.producer = null
        producer?.setCallback(null)
        revoke(session)
        worker.execute {
            main.post {
                release(producer)
                if (session.failure == null) result.success(null)
                else result.error("nativeFailure", session.failure, null)
            }
        }
    }

    private fun close(session: Session, result: MethodChannel.Result?) {
        session.closed = true
        session.invalidate()
        sessions.remove(session.id)
        val producer = session.producer
        session.producer = null
        producer?.setCallback(null)
        worker.execute {
            var failure: Exception? = null
            try { if (session.handle != 0L) Native.destroy(session.handle) }
            catch (error: Exception) { failure = error }
            session.handle = 0L
            main.post {
                release(producer)
                if (failure == null) result?.success(null)
                else result?.error("nativeFailure", failure.message, null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try { handle(call, result) }
        catch (error: Exception) { result.error("nativeFailure", error.message, null) }
    }

    private fun info(handle: Long): MutableMap<String, Any?> {
        val json = JSONObject(Native.info(handle))
        val info = mutableMapOf<String, Any?>()
        json.keys().forEach { key -> info[key] = json.get(key).let { if (it == JSONObject.NULL) null else it } }
        return info
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (BuildConfig.DEBUG) {
            when (call.method) {
                "debugArmPublication" -> {
                    check(testGate == null) { "A publication gate is already armed." }
                    testGate = PublicationGate()
                    result.success(null); return
                }
                "debugPublicationState" -> {
                    result.success(mapOf("entered" to (testGate?.entered == true), "timedOut" to (testGate?.timedOut == true))); return
                }
                "debugReleasePublication" -> {
                    val gate = testGate
                    testGate = null
                    gate?.release?.countDown()
                    if (gate?.timedOut == true) result.error("gateTimeout", "Publication gate timed out.", null)
                    else result.success(null)
                    return
                }
            }
        }
        if (call.method == "connect") {
            check(Build.VERSION.SDK_INT >= 29) { "Android native GPU presentation requires API 29 or newer." }
            Native.connect(call.argument<Number>("runtime")!!.toLong())
            connected = true
            result.success(null)
            return
        }
        check(connected) { "Connect Dart's loaded Rust runtime first." }
        if (call.method == "diagnostics") {
            val values = Native.counters()
            result.success(mapOf("sessions" to sessions.size, "surfaces" to surfaceCount,
                "renderers" to values[0], "retiring" to values[1],
                "presented" to presentedCount, "readbackBytes" to readbackBytes))
            return
        }
        if (call.method == "create") {
            check(sessions.size < 32) { "Native surface capacity exhausted." }
            val session = Session(nextId++)
            sessions[session.id] = session
            if (call.argument<Boolean>("deferredAttachment") != true) allocate(session)
            worker.execute {
                try {
                    session.handle = Native.create()
                    val data = info(session.handle)
                    main.post {
                        if (session.closed || !attached) result.error("disposed", "Renderer closed during creation.", null)
                        else {
                            data["session"] = session.id
                            data["texture"] = session.producer?.id()
                            result.success(data)
                        }
                    }
                } catch (error: Exception) {
                    main.post {
                        if (!session.closed) close(session, null)
                        result.error("nativeFailure", error.message, null)
                    }
                }
            }
            return
        }
        val session = sessions[call.argument<Number>("session")?.toLong()]
        if (session == null && call.method == "detach") { result.success(null); return }
        checkNotNull(session) { "Invalid or closed surface session." }
        val attachment = call.argument<Number>("attachment")?.toLong()
        when (call.method) {
            "close" -> close(session, result)
            "gpu" -> {
                val operation = when (call.argument<String>("operation")) {
                    "resource" -> 0; "shader" -> 1; "graph" -> 2
                    else -> throw IllegalArgumentException("Unknown GPU operation.")
                }
                val bytes = checkNotNull(call.argument<ByteArray>("data"))
                val requestedCapacity = checkNotNull(call.argument<Number>("capacity")).toLong()
                require(if (operation == 0) bytes.size <= 64 * 1024 * 1024 + 2048 &&
                    requestedCapacity in 24L..(64L * 1024 * 1024 + 24)
                    else bytes.size <= 8 * 1024 * 1024 && requestedCapacity == 256L * 1024) {
                    "GPU command exceeds its transfer limits."
                }
                worker.execute {
                    try {
                        check(!session.closed) { "Native session has closed." }
                        val reply = Native.gpu(session.handle, operation, bytes, requestedCapacity.toInt())
                        check(reply.size >= 4) { "GPU response is truncated." }
                        val status = java.nio.ByteBuffer.wrap(reply, 0, 4)
                            .order(java.nio.ByteOrder.LITTLE_ENDIAN).int
                        val data = reply.copyOfRange(4, reply.size)
                        main.post { result.success(mapOf("status" to status, "data" to data,
                            "error" to if (status == 0) "" else data.toString(Charsets.UTF_8))) }
                    } catch (error: Exception) {
                        main.post { result.error("nativeFailure", error.message, null) }
                    }
                }
            }
            "prepare" -> {
                checkNotNull(attachment)
                require(attachment > 0 && attachment >= session.attachment &&
                    !(attachment == session.attachment && session.attachmentClosed)) { "Stale surface attachment." }
                if (attachment > session.attachment) {
                    check(session.producer == null) { "Detach the current view before attaching another." }
                    session.attachment = attachment
                    session.attachmentClosed = false
                    session.suspended = false
                    session.invalidate()
                    allocate(session)
                }
                if (session.suspended || !session.available) {
                    result.error("frameDeferred", "Android surface is suspended.", null); return
                }
                prepareSurface(session, call)
                result.success(mapOf("texture" to session.producer!!.id(), "epoch" to session.epoch))
            }
            "detach" -> {
                if (attachment != session.attachment || session.attachmentClosed) result.success(null)
                else detach(session, result)
            }
            "suspend" -> {
                if (attachment == null || (attachment == session.attachment && !session.attachmentClosed)) {
                    val suspended = call.argument<Boolean>("suspended") == true
                    if (session.suspended != suspended) { session.suspended = suspended; revoke(session) }
                }
                result.success(null)
            }
            "present" -> result.success(!session.closed && !session.suspended && session.available &&
                !session.attachmentClosed && attachment == session.attachment &&
                call.argument<Number>("epoch")?.toLong() == session.epoch &&
                call.argument<Number>("frame")?.toLong() == session.presentedFrame)
            "replace" -> {
                revoke(session)
                session.producer?.setSize(session.width + 1, session.height)
                result.success(null)
            }
            "render" -> render(session, call, result)
            else -> result.notImplemented()
        }
    }

    private fun prepareSurface(session: Session, call: MethodCall): Surface {
        session.failure?.let { throw IllegalStateException(it) }
        val width = call.argument<Number>("width")!!.toInt()
        val height = call.argument<Number>("height")!!.toInt()
        require(width in 1..4096 && height in 1..4096) { "Surface dimensions must be between 1 and 4096." }
        val producer = checkNotNull(session.producer) { "Surface is detached." }
        val resized = session.width != width || session.height != height
        producer.setSize(width, height)
        val surface = producer.surface
        if (resized || surface !== session.surface) { session.invalidate(); session.presentedFrame = 0 }
        session.surface = surface
        session.width = width
        session.height = height
        return surface
    }

    private fun render(session: Session, call: MethodCall, result: MethodChannel.Result) {
        session.failure?.let { throw IllegalStateException(it) }
        val attachment = call.argument<Number>("attachment")?.toLong()
        val requestedEpoch = call.argument<Number>("epoch")?.toLong()
        if (session.suspended || !session.available || session.producer == null ||
            (attachment != null && (session.attachmentClosed || attachment != session.attachment || requestedEpoch != session.epoch))) {
            result.success(mapOf("presented" to false, "applied" to false)); return
        }
        check(!session.busy) { "A Vulkan frame is already in flight." }
        val surface = prepareSurface(session, call)
        if (requestedEpoch != null && requestedEpoch != session.epoch) {
            result.success(mapOf("presented" to false, "applied" to false)); return
        }
        val packet = when (val value = call.argument<Any>("scene")) {
            is ByteArray -> value
            is String -> value.toByteArray(Charsets.UTF_8)
            else -> throw IllegalArgumentException("A binary scene packet is required.")
        }
        require(packet.size <= 128 * 1024 * 1024) { "Scene packet exceeds the native limit." }
        val generation = session.generation.get()
        val epoch = generation.epoch
        val width = session.width
        val height = session.height
        val frame = call.argument<Number>("frame")?.toLong() ?: 0L
        session.busy = true
        worker.execute {
            try {
                var published = false
                var applied = false
                if (!session.closed && session.epoch == epoch) {
                    val rendered = Native.render(session.handle, surface, packet, width, height)
                    applied = rendered
                    if (rendered && !session.closed && session.epoch == epoch) {
                        if (BuildConfig.DEBUG) testGate?.waitOnce()
                        // This claim is the publication linearization point. Revocation
                        // that wins the CAS retires the frame. A winning claim owns the
                        // old window until the serial worker finishes present and then
                        // processes detach/close; the platform thread never waits on it.
                        if (session.generation.compareAndSet(generation, Generation(epoch))) {
                            Native.present(session.handle)
                            published = true
                        } else { Native.detach(session.handle) }
                    } else if (rendered) { Native.detach(session.handle) }
                }
                val data = info(session.handle)
                data["applied"] = applied
                data["epoch"] = epoch
                main.post {
                    val current = published && !session.closed && session.epoch == epoch
                    if (published) presentedCount++
                    if (current) session.presentedFrame = frame
                    val readback = (data["readbackBytes"] as Number).toLong()
                    readbackBytes += readback - session.readback
                    session.readback = readback
                    data["presented"] = current
                    session.busy = false
                    result.success(data)
                }
            } catch (error: Exception) {
                main.post { session.busy = false; result.error("nativeFailure", error.message, null) }
            }
        }
    }
}
