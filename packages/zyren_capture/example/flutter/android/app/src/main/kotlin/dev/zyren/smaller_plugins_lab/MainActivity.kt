package dev.zyren.smaller_plugins_lab

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val audio by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private val focus by lazy {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener { change ->
                val state = when (change) {
                    AudioManager.AUDIOFOCUS_GAIN -> "gain"
                    AudioManager.AUDIOFOCUS_LOSS -> "loss"
                    else -> "transientLoss"
                }
                channel.invokeMethod("focus", state)
            }.build()
    }
    private val routeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                channel.invokeMethod("focus", "routeLost")
                audio.abandonAudioFocusRequest(focus)
            }
        }
    }
    private var receiverRegistered = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zyren/smaller-lab/audio-session")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> result.success(audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                "release" -> { audio.abandonAudioFocusRequest(focus); result.success(null) }
                else -> result.notImplemented()
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(routeReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(routeReceiver, filter)
        }
        receiverRegistered = true
    }
    override fun onDestroy() {
        if (receiverRegistered) unregisterReceiver(routeReceiver)
        audio.abandonAudioFocusRequest(focus)
        if (::channel.isInitialized) channel.setMethodCallHandler(null)
        super.onDestroy()
    }
}
