package app.capyvibe.phrayo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    private val host get() = AndroidHost.get(this)
    private var permission: CompletableDeferred<Boolean>? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        host.activity = WeakReference(this)
        PhrayoNative.setUp(flutterEngine.dartExecutor.binaryMessenger, host)
        host.events = PhrayoEvents(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.capyvibe.phrayo/android").setMethodCallHandler { call, result ->
            when (call.method) {
                "cancelTranscription" -> { host.cancelTranscription(call.arguments as String); result.success(null) }
                "licenses" -> result.success(assets.list("licenses")!!.associateWith { name -> assets.open("licenses/$name").bufferedReader().use { it.readText() } })
                else -> result.notImplemented()
            }
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); handleShortcut(intent) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleShortcut(intent) }
    private fun handleShortcut(intent: Intent) {
        if (intent.action != "app.capyvibe.phrayo.START_SPEAKING") return
        intent.action = Intent.ACTION_MAIN
        window.decorView.post { host.scope.launch {
            runCatching { host.startShortcut() }.onFailure {
                val message = if ((it as? FlutterError)?.code == "permission_granted_retry") R.string.microphone_ready else R.string.shortcut_failed
                android.widget.Toast.makeText(this@MainActivity, message, android.widget.Toast.LENGTH_LONG).show()
            }
        } }
    }
    suspend fun requireMicrophone() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                !getPreferences(MODE_PRIVATE).getBoolean("notificationsAsked", false)) {
                getPreferences(MODE_PRIVATE).edit().putBoolean("notificationsAsked", true).apply()
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 42)
            }
            return
        }
        if (permission != null) problem("permission_pending")
        val request = CompletableDeferred<Boolean>(); permission = request
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 41)
        try { problem(if (request.await()) "permission_granted_retry" else "microphone_denied") }
        finally { permission = null }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 41) permission?.complete(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }
    override fun onDestroy() {
        permission?.complete(false)
        if (host.activity.get() === this) { host.activity.clear(); host.events = null }
        super.onDestroy()
    }
    override fun onTrimMemory(level: Int) { super.onTrimMemory(level); if (level >= TRIM_MEMORY_RUNNING_LOW) host.trimMemory() }
}
