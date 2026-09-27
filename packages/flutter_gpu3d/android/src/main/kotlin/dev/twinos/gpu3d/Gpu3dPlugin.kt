package dev.twinos.gpu3d

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
import org.json.JSONObject

internal object Native {
    init { System.loadLibrary("gpu3d_surface") }
    external fun connect(runtime: Long)
    external fun create(): Long
    external fun destroy(handle: Long)
    external fun detach(handle: Long)
    external fun render(handle: Long, surface: Surface, packet: ByteArray, width: Int, height: Int): Boolean
    external fun present(handle: Long)
    external fun info(handle: Long): String
    external fun counters(): LongArray
}

/** Internal Vulkan qualification bridge. SceneView selection remains unchanged. */
class Gpu3dPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var textures: TextureRegistry
    private lateinit var channel: MethodChannel
    private val sessions = mutableMapOf<Long, Session>()
    private var nextId = 1L
    private var connected = false
    private var attached = false

    private class Session(val id: Long, val producer: TextureRegistry.SurfaceProducer) {
        var handle = 0L // Native worker only until creation completes.
        @Volatile var epoch = 1L
        @Volatile var closed = false
        @Volatile var available = true
        @Volatile var suspended = false
        @Volatile var failure: String? = null
        var busy = false // Platform thread only.
        var surface: Surface? = null // Identity only; fetch producer.surface for every frame.
        var width = 1
        var height = 1
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "gpu3d/android-proof")
        channel.setMethodCallHandler(this)
        attached = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        sessions.values.toList().forEach { close(it, null) }
        worker.shutdown()
    }

    private fun revoke(session: Session) {
        session.epoch++
        session.surface = null
        worker.execute {
            try { if (session.handle != 0L) Native.detach(session.handle) }
            catch (error: Exception) { session.failure = error.message ?: "Native detach failed." }
        }
    }

    private fun close(session: Session, result: MethodChannel.Result?) {
        session.closed = true
        session.epoch++
        sessions.remove(session.id)
        session.producer.setCallback(null)
        worker.execute {
            var failure: Exception? = null
            try { if (session.handle != 0L) Native.destroy(session.handle) }
            catch (error: Exception) { failure = error }
            session.handle = 0L
            main.post {
                session.producer.release()
                if (failure == null) result?.success(null)
                else result?.error("nativeFailure", failure.message, null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try { handle(call, result) }
        catch (error: Exception) { result.error("nativeFailure", error.message, null) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
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
            result.success(mapOf("sessions" to sessions.size, "renderers" to values[0], "retiring" to values[1]))
            return
        }
        if (call.method == "create") {
            check(sessions.size < 32) { "Native surface capacity exhausted." }
            val session = Session(nextId++, textures.createSurfaceProducer())
            sessions[session.id] = session
            session.producer.setSize(1, 1)
            session.producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    if (!session.closed) { session.available = true; revoke(session) }
                }
                override fun onSurfaceCleanup() {
                    if (!session.closed) { session.available = false; revoke(session) }
                }
            })
            worker.execute {
                try {
                    session.handle = Native.create()
                    main.post {
                        if (session.closed || !attached) result.error("disposed", "Surface closed during creation.", null)
                        else result.success(mapOf("session" to session.id, "texture" to session.producer.id()))
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
            ?: throw IllegalStateException("Invalid or closed surface session.")
        when (call.method) {
            "close" -> close(session, result)
            "suspend" -> {
                session.suspended = call.argument<Boolean>("suspended") == true
                revoke(session)
                result.success(null)
            }
            "replace" -> {
                revoke(session)
                // Resizing invalidates the producer's current Surface. The next
                // render fetches a fresh one using the public SurfaceProducer API.
                session.producer.setSize(session.width + 1, session.height)
                result.success(null)
            }
            "render" -> render(session, call, result)
            else -> result.notImplemented()
        }
    }

    private fun render(session: Session, call: MethodCall, result: MethodChannel.Result) {
        session.failure?.let { throw IllegalStateException(it) }
        if (session.suspended || !session.available) { result.success(mapOf("presented" to false)); return }
        check(!session.busy) { "A Vulkan frame is already in flight." }
        val width = call.argument<Number>("width")!!.toInt()
        val height = call.argument<Number>("height")!!.toInt()
        require(width in 1..4096 && height in 1..4096) { "Surface dimensions must be between 1 and 4096." }
        val packet = call.argument<String>("scene")!!.toByteArray(Charsets.UTF_8)
        require(packet.size <= 128 * 1024 * 1024) { "Scene packet exceeds the native limit." }
        val resized = session.width != width || session.height != height
        session.producer.setSize(width, height)
        val surface = session.producer.surface
        if (resized || surface !== session.surface) session.epoch++
        session.surface = surface
        session.width = width
        session.height = height
        val epoch = session.epoch
        session.busy = true
        worker.execute {
            try {
                var published = false
                var applied = false
                if (!session.closed && session.epoch == epoch) {
                    val rendered = Native.render(session.handle, surface, packet, width, height)
                    applied = rendered
                    if (rendered && !session.closed && session.epoch == epoch) {
                        Native.present(session.handle)
                        published = true
                    } else if (rendered) { Native.detach(session.handle) }
                }
                val json = JSONObject(Native.info(session.handle))
                val info = mutableMapOf<String, Any?>()
                json.keys().forEach { key -> info[key] = json.get(key).let { if (it == JSONObject.NULL) null else it } }
                info["presented"] = published
                info["applied"] = applied
                info["epoch"] = epoch
                main.post { session.busy = false; result.success(info) }
            } catch (error: Exception) {
                main.post { session.busy = false; result.error("nativeFailure", error.message, null) }
            }
        }
    }
}
