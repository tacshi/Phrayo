package app.capyvibe.phrayo.voiceprobe

import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import android.view.ViewGroup
import android.widget.*
import app.capyvibe.phrayo.voice.NativeVoice
import app.capyvibe.phrayo.voice.JapaneseSpeechText
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Separate development package: measurements here do not claim release acceptance. */
class VoiceProbeActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val control = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    private val handleLock = Any()
    private var handle = 0L
    private var loadedConfiguration = ""
    @Volatile private var track: AudioTrack? = null
    private lateinit var status: TextView
    private lateinit var language: Spinner
    private lateinit var streaming: CheckBox
    private lateinit var editor: EditText
    private lateinit var modelFile: File
    private lateinit var profileFile: File
    private lateinit var models: JSONObject
    private lateinit var reports: File
    private lateinit var japanese: JapaneseSpeechText
    private val languages = listOf("en", "zh", "yue", "ja")
    private val examples = listOf(
        "I'd like to book a table for two tomorrow evening.",
        "我想订一张明天晚上的双人餐桌。",
        "我想訂聽晚兩個人嘅位，唔該。",
        "明日の夜、二人分の席を予約したいです。"
    )
    private val instructions = listOf(
        "Speak clearly and naturally in English.", "请用普通话自然清楚地表达。",
        "请用广东话表达。", "日本語で自然にはっきり話してください。"
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        models = JSONObject(assets.open("dependencies.json").bufferedReader().use { it.readText() }).getJSONObject("models")
        val root = getExternalFilesDir(null) ?: filesDir
        modelFile = File(root, "models/${models.getJSONObject("f16").getString("filename")}")
        profileFile = File(filesDir, "phrayo-lj025.gguf")
        assets.open("phrayo-lj025.gguf").use { input -> profileFile.outputStream().use { input.copyTo(it) } }
        val dictionary = File(filesDir, "ipadic").apply { mkdirs() }
        for (name in listOf("sys.dic", "unk.dic", "char.bin", "matrix.bin", "dicrc")) {
            val output = File(dictionary, name)
            if (!output.exists()) assets.open("ipadic/$name").use { input -> output.outputStream().use { input.copyTo(it) } }
        }
        japanese = JapaneseSpeechText(dictionary)
        reports = File(root, "reports").apply { mkdirs() }
        modelFile.parentFile!!.mkdirs()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 80, 32, 40)
        }
        column.addView(TextView(this).apply { text = "Phrayo · Voice qualification"; textSize = 23f })
        status = TextView(this).apply { textSize = 15f; text = "F16 CPU baseline. Model is downloaded separately." }
        column.addView(status)
        language = Spinner(this).apply {
            adapter = ArrayAdapter(this@VoiceProbeActivity, android.R.layout.simple_spinner_dropdown_item,
                listOf("English", "普通话", "粵語", "日本語"))
        }
        column.addView(language)
        editor = EditText(this).apply { setText(examples[0]); minLines = 3 }
        column.addView(editor)
        language.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: android.view.View?, position: Int, id: Long) {
                editor.setText(examples[position])
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        streaming = CheckBox(this).apply { text = "Stream PCM while generating"; isChecked = false }
        column.addView(streaming)
        fun button(title: String, action: () -> Unit) {
            column.addView(Button(this).apply { text = title; setOnClickListener { action() } })
        }
        button("Download F16 model (1.72 GB)") { download() }
        button("Speak") { runSample(language.selectedItemPosition, editor.text.toString(), streaming.isChecked) }
        button("Stop") { stop() }
        button("Unload model") { stop(); worker.execute { closeModel(); update("Model unloaded") } }
        setContentView(ScrollView(this).apply { addView(column, ViewGroup.LayoutParams(-1, -2)) })
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        if (intent.getBooleanExtra("stop", false)) { stop(); return }
        if (intent.getBooleanExtra("unload", false)) { stop(); worker.execute { closeModel() }; return }
        if (!intent.getBooleanExtra("run_sample", false)) return
        val index = languages.indexOf(intent.getStringExtra("language") ?: "en").coerceAtLeast(0)
        val text = intent.getStringExtra("text") ?: examples[index]
        val stream = intent.getBooleanExtra("streaming", false)
        val variant = intent.getStringExtra("variant") ?: "f16"
        val backend = intent.getStringExtra("backend") ?: "cpu"
        val threads = intent.getIntExtra("threads", 4).coerceIn(1, 8)
        val runId = intent.getStringExtra("run_id")?.takeIf { it.matches(Regex("[A-Za-z0-9-]{1,64}")) }
            ?: System.currentTimeMillis().toString()
        val saveAudio = intent.getBooleanExtra("save_audio", false)
        val cacheSlots = intent.getIntExtra("cache_slots", if (stream) 1 else 0).coerceIn(0, 10)
        val cacheFrames = intent.getIntExtra("cache_frames", 1024).coerceIn(512, 2048)
        val fixedTokens = intent.getStringExtra("fixed_tokens")?.let { raw ->
            val values = raw.split(',').mapNotNull { it.toIntOrNull() }
            if (values.isEmpty() || values.size > 2048 || values.any { it !in 0..6560 }) return
            values.toIntArray()
        }
        window.decorView.post { runSample(index, text, stream, variant, backend, threads, runId, saveAudio, cacheSlots, cacheFrames, fixedTokens) }
    }

    private fun update(message: String) {
        android.util.Log.i("PhrayoVoiceProbe", message)
        runOnUiThread { if (!isDestroyed) status.text = message }
    }

    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                if (cancelled.get()) throw InterruptedException("Cancelled")
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun verifyModel(variant: String): File {
        require(variant == "f16" || variant == "q8") { "Unknown model variant" }
        val definition = models.getJSONObject(variant)
        val selected = File(modelFile.parentFile, definition.getString("filename"))
        check(selected.length() == definition.getLong("bytes")) { "Download the complete $variant model first" }
        val marker = File(selected.parentFile, "verified-$variant")
        val expected = "${selected.length()}:${selected.lastModified()}:${definition.getString("sha256")}"
        if (marker.isFile && marker.readText() == expected) return selected
        update("Verifying model checksum…")
        check(hash(selected) == definition.getString("sha256")) { "Model checksum failed; download again" }
        marker.writeText(expected)
        return selected
    }

    private fun download() {
        if (!running.compareAndSet(false, true)) return
        cancelled.set(false)
        worker.execute {
            var connection: HttpURLConnection? = null
            try {
                val definition = models.getJSONObject("f16")
                val staged = File(modelFile.parentFile, "f16.partial")
                val endpoint = "https://huggingface.co/${models.getString("repository")}/resolve/${models.getString("revision")}/${definition.getString("filename") }"
                connection = URL(endpoint).openConnection() as HttpURLConnection
                connection.connectTimeout = 30000
                connection.readTimeout = 30000
                if (staged.length() > 0) connection.setRequestProperty("Range", "bytes=${staged.length()}-")
                val response = connection.responseCode
                check(response == 200 || response == 206) { "Download returned HTTP $response" }
                val append = response == 206 && staged.length() > 0
                var completed = if (append) staged.length() else 0L
                var lastUpdate = 0L
                java.io.FileOutputStream(staged, append).use { output ->
                    connection.inputStream.use { input ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) {
                            if (cancelled.get()) throw InterruptedException("Download cancelled; tap Download to resume")
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            completed += count
                            if (SystemClock.elapsedRealtime() - lastUpdate > 500) {
                                update("Downloaded ${completed * 100 / definition.getLong("bytes")}%")
                                lastUpdate = SystemClock.elapsedRealtime()
                            }
                        }
                    }
                }
                check(staged.length() == definition.getLong("bytes") && hash(staged) == definition.getString("sha256")) {
                    "Model download failed verification"
                }
                check(staged.renameTo(modelFile)) { "Could not publish model download" }
                update("Model downloaded; run a voice sample")
            } catch (error: Exception) { update(error.message ?: "Download failed") }
            finally { connection?.disconnect(); running.set(false) }
        }
    }

    private fun runSample(index: Int, text: String, stream: Boolean, variant: String = "f16",
        backend: String = "cpu", threads: Int = 4, runId: String = System.currentTimeMillis().toString(),
        saveAudio: Boolean = false, cacheSlots: Int = if (stream) 1 else 0, cacheFrames: Int = 1024,
        fixedTokens: IntArray? = null) {
        if (!running.compareAndSet(false, true)) { update("Stop the current request first"); return }
        cancelled.set(false)
        worker.execute {
            android.util.Log.i("PhrayoVoiceProfile", "BEGIN $runId")
            val report = JSONObject().put("language", languages[index]).put("streaming", stream)
                .put("variant", variant).put("backend", backend).put("threads", threads)
                .put("run_id", runId)
                .put("attention_cache_precision", "f16").put("diffusion_cache_slots", cacheSlots)
                .put("diffusion_cache_frames", cacheFrames).put("fixed_token_count", fixedTokens?.size ?: 0)
            val request = SystemClock.elapsedRealtimeNanos()
            val firstPcm = AtomicLong(0)
            val firstFrame = AtomicLong(0)
            val samplesWritten = AtomicLong(0)
            val audioFailed = AtomicBoolean(false)
            val audibleSignal = AtomicBoolean(false)
            val queue = ArrayBlockingQueue<FloatArray>(24)
            var audioThread: Thread? = null
            var exported: RandomAccessFile? = null
            var exportedBytes = 0L
            val exportPath = File(reports, "$runId.wav")
            val manager = getSystemService(AudioManager::class.java)
            var focus: AudioFocusRequest? = null
            var rate = 24000
            try {
                require(backend == "cpu" || backend == "vulkan") { "Unknown backend" }
                val selectedModel = verifyModel(variant)
                val configuration = "$variant:$backend:$threads:$cacheSlots:$cacheFrames"
                if (loadedConfiguration != configuration) closeModel()
                report.put("cold", synchronized(handleLock) { handle == 0L })
                val loadStart = SystemClock.elapsedRealtimeNanos()
                if (synchronized(handleLock) { handle == 0L }) {
                    update("Loading $variant on $backend…")
                    val loaded = NativeVoice.create(selectedModel.path, profileFile.path, threads, backend == "vulkan", cacheSlots, cacheFrames)
                    synchronized(handleLock) { handle = loaded }
                    loadedConfiguration = configuration
                }
                report.put("load_ms", (SystemClock.elapsedRealtimeNanos() - loadStart) / 1e6)
                if (cancelled.get()) throw InterruptedException("Cancelled")
                val active = synchronized(handleLock) { handle }
                rate = NativeVoice.sampleRate(active)
                val format = AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build()
                val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
                focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attributes).setOnAudioFocusChangeListener { change ->
                        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stop()
                    }.build()
                check(manager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    "Audio focus unavailable; keep the app visible and retry"
                }
                report.put("media_volume", manager.getStreamVolume(AudioManager.STREAM_MUSIC))
                val audio = AudioTrack.Builder().setAudioFormat(format)
                    .setAudioAttributes(attributes)
                    .setBufferSizeInBytes(maxOf(rate * 2, AudioTrack.getMinBufferSize(rate,
                        AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)))
                    .setTransferMode(AudioTrack.MODE_STREAM).build()
                track = audio
                if (saveAudio) exported = RandomAccessFile(exportPath, "rw").apply { setLength(0); write(ByteArray(44)) }
                audioThread = Thread({
                    try {
                        var started = false
                        while (!cancelled.get()) {
                            val block = queue.poll(50, TimeUnit.MILLISECONDS) ?: continue
                            if (block.isEmpty()) break
                            var offset = 0
                            while (offset < block.size && !cancelled.get()) {
                                val count = audio.write(block, offset, block.size - offset, AudioTrack.WRITE_BLOCKING)
                                check(count > 0) { "AudioTrack write failed: $count" }
                                offset += count
                                samplesWritten.addAndGet(count.toLong())
                                if (!started) { audio.play(); started = true }
                                val timestamp = AudioTimestamp()
                                if (firstFrame.get() == 0L && audio.getTimestamp(timestamp) && timestamp.framePosition > 0) {
                                    firstFrame.compareAndSet(0, SystemClock.elapsedRealtimeNanos())
                                }
                            }
                        }
                        val deadline = SystemClock.elapsedRealtime() + 30000
                        while (!cancelled.get() && audio.playbackHeadPosition.toLong() < samplesWritten.get()
                            && SystemClock.elapsedRealtime() < deadline) {
                            if (firstFrame.get() == 0L && audio.playbackHeadPosition > 0) firstFrame.compareAndSet(0, SystemClock.elapsedRealtimeNanos())
                            Thread.sleep(10)
                        }
                        report.put("underruns", audio.underrunCount)
                        report.put("audio_route_type", audio.routedDevice?.type ?: JSONObject.NULL)
                    } catch (error: Exception) { audioFailed.set(true); update("Playback failed: ${error.message}") }
                }, "phrayo-pcm").apply { start() }
                update("Synthesizing ${languages[index]} (${if (stream) "streaming" else "whole utterance"})…")
                val synthesisStart = SystemClock.elapsedRealtimeNanos()
                val spoken = if (index == 3) japanese.readings(text) else text
                val completed = NativeVoice.synthesize(active, spoken.toByteArray(Charsets.UTF_8),
                    instructions[index].toByteArray(Charsets.UTF_8), stream, fixedTokens, NativeVoice.PcmListener { block ->
                        if (firstPcm.compareAndSet(0, SystemClock.elapsedRealtimeNanos())) {
                            update("First PCM after ${(firstPcm.get() - request) / 1e6} ms")
                        }
                        if (block.any { kotlin.math.abs(it) > 0.00001f }) audibleSignal.set(true)
                        exported?.let { output ->
                            val data = ByteBuffer.allocate(block.size * 4).order(ByteOrder.LITTLE_ENDIAN)
                            for (sample in block) data.putFloat(sample)
                            output.write(data.array())
                            exportedBytes += data.capacity()
                        }
                        var accepted = false
                        while (!cancelled.get() && !audioFailed.get() && !accepted) accepted = queue.offer(block, 50, TimeUnit.MILLISECONDS)
                        accepted
                    })
                report.put("synthesis_ms", (SystemClock.elapsedRealtimeNanos() - synthesisStart) / 1e6)
                while (!cancelled.get() && !audioFailed.get() && !queue.offer(FloatArray(0), 50, TimeUnit.MILLISECONDS)) {}
                audioThread.join(35000)
                check(!audioThread.isAlive && !audioFailed.get()) { "Audio did not finish" }
                check(cancelled.get() || audibleSignal.get()) { "Synthesis returned silent audio" }
                report.put("completed", completed && !cancelled.get())
                if (completed && !cancelled.get() && exported != null) {
                    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                    header.put("RIFF".toByteArray()).putInt((36 + exportedBytes).toInt()).put("WAVEfmt ".toByteArray())
                    header.putInt(16).putShort(3).putShort(1).putInt(rate).putInt(rate * 4)
                    header.putShort(4).putShort(32).put("data".toByteArray()).putInt(exportedBytes.toInt())
                    exported!!.seek(0); exported!!.write(header.array())
                    report.put("audio_file", exportPath.name)
                }
                report.put("audio_seconds", samplesWritten.get().toDouble() / rate)
                report.put("first_pcm_ms", if (firstPcm.get() == 0L) JSONObject.NULL else (firstPcm.get() - request) / 1e6)
                report.put("first_observed_playback_frame_ms", if (firstFrame.get() == 0L) JSONObject.NULL else (firstFrame.get() - request) / 1e6)
            } catch (error: Throwable) {
                cancelled.set(true)
                report.put("error", error.message ?: error.javaClass.simpleName)
            } finally {
                cancelled.set(true)
                audioThread?.join(2000)
                track?.let { audio -> runCatching { audio.pause(); audio.flush(); audio.release() } }
                track = null
                exported?.close()
                if (!report.has("audio_file")) exportPath.delete()
                focus?.let { manager.abandonAudioFocusRequest(it) }
                val memory = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
                report.put("ending_pss_kib", memory.totalPss)
                report.put("wall_ms", (SystemClock.elapsedRealtimeNanos() - request) / 1e6)
                report.put("acoustic_latency_measured", false)
                android.util.Log.i("PhrayoVoiceProfile", "END $runId")
                File(reports, "latest.json").writeText(report.toString(2))
                update(report.toString(2))
                running.set(false)
            }
        }
    }

    private fun stop() {
        cancelled.set(true)
        track?.let { audio -> runCatching { audio.pause(); audio.flush() } }
        if (!control.isShutdown) control.execute { synchronized(handleLock) { if (handle != 0L) NativeVoice.stop(handle) } }
    }

    private fun closeModel() {
        synchronized(handleLock) { if (handle != 0L) { NativeVoice.destroy(handle); handle = 0L } }
    }

    override fun onDestroy() {
        stop()
        worker.execute { closeModel() }
        worker.shutdown()
        control.shutdown()
        super.onDestroy()
    }
}
