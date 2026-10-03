package dev.zyren.audio_focus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioFocusPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    // AudioManager focus is process-wide. Another Flutter engine cannot take it.
    companion object { private var owner: AudioFocusPlugin? = null }
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var audio: AudioManager
    private lateinit var focus: AudioFocusRequest
    private var receiverRegistered = false
    private val routeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (owner === this@AudioFocusPlugin && intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                channel.invokeMethod("focus", "routeLost")
                audio.abandonAudioFocusRequest(focus)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        channel = MethodChannel(binding.binaryMessenger, "zyren/audio-session")
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener({ change ->
                if (owner === this) {
                    val state = when (change) {
                        AudioManager.AUDIOFOCUS_GAIN -> "gain"
                        AudioManager.AUDIOFOCUS_LOSS -> "loss"
                        else -> "transientLoss"
                    }
                    channel.invokeMethod("focus", state)
                }
            }, Handler(Looper.getMainLooper())).build()
        channel.setMethodCallHandler(this)
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(routeReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(routeReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "acquire" -> {
                    if (owner != null && owner !== this) { result.success(false); return }
                    owner = this
                    val granted = audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                    if (!granted) owner = null
                    result.success(granted)
                }
                "release" -> {
                    if (owner === this) {
                        audio.abandonAudioFocusRequest(focus)
                        owner = null
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: RuntimeException) {
            result.error("audioSession", error.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (receiverRegistered) context.unregisterReceiver(routeReceiver)
        receiverRegistered = false
        if (owner === this) {
            audio.abandonAudioFocusRequest(focus)
            owner = null
        }
        channel.setMethodCallHandler(null)
    }
}
