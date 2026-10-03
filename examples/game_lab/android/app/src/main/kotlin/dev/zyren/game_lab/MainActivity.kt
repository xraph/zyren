package dev.zyren.game_lab

import android.hardware.input.InputManager
import android.os.Handler
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity

class MainActivity : FlutterActivity(), GamepadsCompatibleActivity {
    private var keys: ((KeyEvent) -> Boolean)? = null
    private var motion: ((MotionEvent) -> Boolean)? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        keys?.invoke(event) == true || super.dispatchKeyEvent(event)

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        motion?.invoke(event) == true || super.dispatchGenericMotionEvent(event)

    override fun registerInputDeviceListener(
        listener: InputManager.InputDeviceListener,
        handler: Handler?
    ) {
        (getSystemService(INPUT_SERVICE) as InputManager)
            .registerInputDeviceListener(listener, handler)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        keys = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        motion = handler
    }
}
