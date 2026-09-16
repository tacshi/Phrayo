package app.capyvibe.phrayo

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import kotlinx.coroutines.launch

class MediaSessionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = AndroidHost.get(this)
        when (intent?.action) {
            "pause" -> host.scope.launch { host.pause() }
            "resume" -> host.scope.launch { host.resume() }
            "stop" -> host.scope.launch { if (host.recording) host.stop() else host.stopPlayback() }
            "update" -> {
                val microphone = intent.getBooleanExtra("microphone", false)
                val playback = intent.getBooleanExtra("playback", false)
                if (!microphone && !playback) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY }
                val manager = getSystemService(NotificationManager::class.java)
                manager.createNotificationChannel(NotificationChannel("audio", getString(R.string.audio_channel), NotificationManager.IMPORTANCE_LOW))
                val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val notification = Notification.Builder(this, "audio").setSmallIcon(R.drawable.ic_audio)
                    .setContentTitle(getString(if (microphone) R.string.recording else R.string.playing))
                    .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
                fun action(label: Int, name: String) {
                    val command = PendingIntent.getService(this, label, Intent(this, MediaSessionService::class.java).setAction(name), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    notification.addAction(Notification.Action.Builder(null, getString(label), command).build())
                }
                if (microphone && host.snapshot()?.kind == "recording") {
                    if (intent.getBooleanExtra("paused", false)) action(R.string.resume, "resume") else action(R.string.pause, "pause")
                }
                action(R.string.stop, "stop")
                val type = (if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0) or
                    (if (playback) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0)
                startForeground(1, notification.build(), type)
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        val host = AndroidHost.get(this)
        if (host.recording) host.scope.launch { host.interrupt("audio_interrupted") }
        super.onDestroy()
    }
    companion object {
        private var running = false
        fun update(context: Context, microphone: Boolean, paused: Boolean, playback: Boolean) {
            if (!microphone && !playback && !running) return
            val intent = Intent(context, MediaSessionService::class.java).setAction("update")
                .putExtra("microphone", microphone).putExtra("paused", paused).putExtra("playback", playback)
            if (microphone || playback) context.startForegroundService(intent) else context.startService(intent)
            running = microphone || playback
        }
    }
}
