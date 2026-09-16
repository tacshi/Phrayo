package app.capyvibe.phrayo

import android.app.KeyguardManager
import android.content.Intent
import android.os.SystemClock
import android.view.WindowManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class VoiceLifecycleTest {
    @Test fun cancelDuringInferenceThenRetryAndReplayCachedVoice() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeFalse("Unlock the phone for playback", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        assumeTrue("Stage the F16 test model first", File(context.noBackupFilesDir, "models/.cosyvoice3-f16-lj025-v1/CosyVoice3-2512_F16.gguf").exists() ||
            File(context.noBackupFilesDir, "models/cosyvoice3-f16-lj025-v1/verified").exists())
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        instrumentation.runOnMainSync { activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val runtime = VoiceRuntime(context, InferenceGate(), scope)
        val playback = withContext(Dispatchers.Main) { SpeechPlayback(context, scope, runtime) {} }
        try {
            withContext(Dispatchers.Main) { runtime.prepare {} }
            assertEquals("ready", runtime.status("en-US"))
            withContext(Dispatchers.Main) {
                val pending = async { runtime.synthesize("This sentence is deliberately cancelled.", "en-US") }
                delay(300)
                runtime.cancel()
                withTimeout(15_000) { pending.join() }
                assertTrue(pending.isCancelled)
            }
            withContext(Dispatchers.Main) { withTimeout(180_000) { runtime.synthesize(VoiceRuntime.sample("en-US"), "en-US") } }
            val started = SystemClock.elapsedRealtime()
            withContext(Dispatchers.Main) { withTimeout(10_000) { playback.speak(VoiceRuntime.sample("en-US"), "en-US", true) } }
            assertTrue("Cached replay must avoid another inference", SystemClock.elapsedRealtime() - started < 10_000)
        } finally {
            withContext(Dispatchers.Main) { playback.stop(); runtime.stopAndJoin(); runtime.trim(); activity.finish() }
        }
    }
}
