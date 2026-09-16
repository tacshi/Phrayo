package app.capyvibe.phrayo

import android.content.*
import android.media.*
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import app.capyvibe.phrayo.voice.JapaneseSpeechText
import app.capyvibe.phrayo.voice.NativeVoice
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class PcmOutput(rate: Int) {
    private val stopped = AtomicBoolean(false)
    private val queue = ArrayBlockingQueue<FloatArray>(24)
    private val track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(rate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
        .setBufferSizeInBytes(maxOf(rate * 4 / 2, AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)))
        .setTransferMode(AudioTrack.MODE_STREAM).build()
    private val complete = CompletableDeferred<Unit>()
    private val thread = Thread({
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        var frames = 0L
        try {
            track.play()
            while (!stopped.get()) {
                val block = queue.take()
                if (block.isEmpty()) break
                var offset = 0
                while (offset < block.size && !stopped.get()) {
                    val written = track.write(block, offset, block.size - offset, AudioTrack.WRITE_BLOCKING)
                    if (written <= 0) error("audio_playback_failed")
                    offset += written; frames += written
                }
            }
            while (!stopped.get() && (track.playbackHeadPosition.toLong() and 0xffffffffL) < frames) Thread.sleep(10)
            complete.complete(Unit)
        } catch (error: Exception) {
            if (stopped.get()) complete.complete(Unit) else complete.completeExceptionally(error)
        } finally { runCatching { track.stop() }; track.release() }
    }, "phrayo-pcm").apply { start() }
    fun append(block: FloatArray): Boolean {
        val copy = block.copyOf()
        while (!stopped.get() && !complete.isCompleted) if (queue.offer(copy, 50, TimeUnit.MILLISECONDS)) return true
        return false
    }
    suspend fun finish() { withContext(Dispatchers.IO) { append(FloatArray(0)) }; complete.await() }
    fun stop() {
        if (stopped.getAndSet(true)) return
        runCatching { track.pause(); track.flush() }
        queue.clear(); queue.offer(FloatArray(0)); thread.interrupt()
    }
}

internal class VoiceRuntime(private val context: Context, private val gate: InferenceGate,
    private val scope: CoroutineScope) {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "phrayo-inference") }.asCoroutineDispatcher()
    private val control = Executors.newSingleThreadExecutor { Thread(it, "phrayo-cancel") }
    private val nativeLock = Any()
    private var handle = 0L
    private var idle: Job? = null
    private var task: Deferred<Unit>? = null
    private var preparation: Deferred<Unit>? = null
    private var generation = 0L
    private val cache = LinkedHashMap<String, FloatArray>(16, 0.75f, true)
    private var cacheBytes = 0
    private val assets = File(context.noBackupFilesDir, "voice-assets")
    private val models = JSONObject(context.assets.open("dependencies.json").bufferedReader().use { it.readText() }).getJSONObject("models")
    private val model = models.getJSONObject("f16")
    val store = ModelStore(context, "cosyvoice3-f16-lj025-v1", listOf(ModelFile(model.getString("filename"),
        model.getLong("bytes"), model.getString("sha256"),
        "https://huggingface.co/${models.getString("repository")}/resolve/${models.getString("revision")}/${model.getString("filename")}")))
    fun supported(language: String) = languageCode(language) in setOf("en", "zh", "ja", "yue")
    fun status(language: String) = when {
        !supported(language) -> "unsupported"
        preparation?.isActive == true -> "downloading"
        store.installed() -> "ready"
        store.directory.exists() -> "repair"
        else -> "download"
    }
    private fun copyAssets() {
        assets.mkdirs()
        for (name in listOf("phrayo-lj025.gguf") + context.assets.list("ipadic")!!.map { "ipadic/$it" }) {
            val file = File(assets, name)
            if (!file.exists()) {
                file.parentFile!!.mkdirs()
                context.assets.open(name).use { input -> file.outputStream().use { input.copyTo(it) } }
            }
        }
    }
    private fun load(directory: File): Long {
        if (handle != 0L) return handle
        copyAssets()
        val loaded = try { NativeVoice.create(File(directory, model.getString("filename")).path,
            File(assets, "phrayo-lj025.gguf").path, 4, false, 1, 1024) }
        catch (error: Exception) { store.invalidate(); throw FlutterError("tts_failure", null, null) }
        if (loaded == 0L) problem("tts_failure")
        synchronized(nativeLock) { handle = loaded }
        return loaded
    }
    private fun unload() = synchronized(nativeLock) {
        if (handle != 0L) NativeVoice.destroy(handle)
        handle = 0L
    }
    fun cancel() {
        generation++
        task?.cancel()
        // Repeat until the serialized worker exits, including cancellation during model loading.
        val cancelling = task
        control.execute {
            while (cancelling != null && !cancelling.isCompleted) {
                synchronized(nativeLock) { if (handle != 0L) NativeVoice.stop(handle) }
                Thread.sleep(20)
            }
        }
    }
    suspend fun stopAndJoin() { val previous = task; cancel(); previous?.join() }
    suspend fun prepare(progress: (Double) -> Unit) {
        if (preparation?.isActive == true) { preparation!!.await(); return }
        preparation = scope.async {
            store.prepare(progress) { directory ->
                stopAndJoin()
                gate.run { withContext(worker) {
                    unload()
                    try {
                        val current = load(directory)
                        val job = currentCoroutineContext()
                        var count = 0
                        if (!NativeVoice.synthesize(current, sample("en").toByteArray(), instruction("en").toByteArray(), false, null) {
                            count += it.size; job.isActive && it.all(Float::isFinite)
                        } || count == 0) problem("tts_install_failed")
                        job.ensureActive()
                    } finally { unload() }
                } }
            }
        }
        preparation!!.await()
    }
    suspend fun cancelPreparation() {
        store.cancel(); preparation?.cancel()
        control.execute { synchronized(nativeLock) { if (handle != 0L) NativeVoice.stop(handle) } }
        preparation?.join()
    }
    suspend fun synthesize(text: String, language: String, output: ((Int) -> PcmOutput)? = null) {
        val previous = task
        cancel()
        val request = generation
        previous?.join()
        if (generation != request) throw CancellationException()
        idle?.cancel()
        val operation = scope.async<Unit> {
            gate.run { withContext(worker) {
                val key = "$language\u0000$text"
                val cached = cache[key]
                var sink: PcmOutput? = null
                try {
                    if (cached != null) {
                        sink = output?.invoke(24000)
                        cached.asList().chunked(4800).forEach { currentCoroutineContext().ensureActive(); sink?.append(it.toFloatArray()) }
                    } else {
                        if (!store.installed()) problem("tts_resources_missing")
                        val current = load(store.directory)
                        currentCoroutineContext().ensureActive()
                        val normalized = if (languageCode(language) == "ja") try {
                            JapaneseSpeechText(File(assets, "ipadic")).readings(text)
                        } catch (_: Exception) { problem("japanese_reading_missing") } else text
                        val rate = NativeVoice.sampleRate(current)
                        check(rate == 24000)
                        sink = output?.invoke(rate)
                        val chunks = mutableListOf<FloatArray>()
                        var bytes = 0
                        val job = currentCoroutineContext()
                        for (part in VoiceTextSegments.split(normalized, language)) {
                            job.ensureActive()
                            val success = NativeVoice.synthesize(current, part.toByteArray(), instruction(language).toByteArray(), true, null) { block ->
                                if (!job.isActive || block.any { !it.isFinite() }) false else {
                                    bytes += block.size * 4
                                    if (bytes <= 4 * 1024 * 1024) chunks.add(block.copyOf()) else chunks.clear()
                                    sink?.append(block) ?: true
                                }
                            }
                            job.ensureActive()
                            if (!success) problem("tts_failure")
                        }
                        job.ensureActive()
                        if (bytes == 0) problem("tts_failure")
                        if (chunks.isNotEmpty()) {
                            val pcm = FloatArray(bytes / 4); var offset = 0
                            chunks.forEach { it.copyInto(pcm, offset); offset += it.size }
                            cache[key] = pcm; cacheBytes += bytes
                            while (cache.size > 12 || cacheBytes > 4 * 1024 * 1024) {
                                val first = cache.entries.iterator(); cacheBytes -= first.next().value.size * 4; first.remove()
                            }
                        }
                    }
                    sink?.finish()
                } finally { sink?.stop() }
            } }
        }
        task = operation
        try { operation.await() } finally {
            if (task === operation) idle = scope.launch { delay(60_000); withContext(worker) { unload() } }
        }
    }
    fun trim() {
        cancel()
        scope.launch { task?.join(); withContext(worker) { unload(); cache.clear(); cacheBytes = 0 } }
    }
    companion object {
        fun sample(language: String) = when (languageCode(language)) {
            "zh" -> "我想订一张明天晚上的双人餐桌。"
            "yue" -> "我想訂聽晚兩個人嘅位，唔該。"
            "ja" -> "明日の夜、二人分の席を予約したいです。"
            "es" -> "Practica un poco cada día y di lo que quieres decir."
            "fr" -> "Pratiquez un peu chaque jour et dites ce que vous voulez dire."
            "pt" -> "Pratique um pouco todos os dias e diga o que quer dizer."
            "vi" -> "Luyện tập một chút mỗi ngày và nói điều bạn muốn nói."
            "th" -> "ฝึกฝนวันละนิด แล้วพูดสิ่งที่คุณอยากพูด"
            "id" -> "Berlatihlah sedikit setiap hari dan katakan apa yang ingin kamu katakan."
            "de" -> "Übe jeden Tag ein wenig und sage, was du sagen möchtest."
            "ko" -> "매일 조금씩 연습하고 하고 싶은 말을 해 보세요."
            "it" -> "Esercitati un po’ ogni giorno e di’ quello che vuoi dire."
            "ar" -> "تدرّب قليلاً كل يوم وقل ما تريد قوله."
            "hi" -> "हर दिन थोड़ा अभ्यास करें और जो कहना चाहते हैं, कहें।"
            else -> "I'd like to book a table for two tomorrow evening."
        }
        fun instruction(language: String) = when (languageCode(language)) {
            "zh" -> "请用普通话自然清楚地表达。"; "yue" -> "请用广东话表达。"
            "ja" -> "日本語で自然にはっきり話してください。"; else -> "Speak clearly and naturally in English."
        }
    }
}

internal class SpeechPlayback(private val context: Context, private val scope: CoroutineScope,
    val voice: VoiceRuntime, private val active: (Boolean) -> Unit) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val ready = CompletableDeferred<Unit>()
    private val system = TextToSpeech(context) { if (it == TextToSpeech.SUCCESS) ready.complete(Unit) else ready.completeExceptionally(FlutterError("tts_failure", null, null)) }
    private var utterance: CompletableDeferred<Unit>? = null
    private var utteranceId: String? = null
    private var job: Deferred<Unit>? = null
    private var player: MediaPlayer? = null
    @Volatile private var pcm: PcmOutput? = null
    private var focus: AudioFocusRequest? = null
    private var generation = 0L
    init {
        system.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String) {}
            override fun onDone(id: String) { scope.launch { if (id == utteranceId) utterance?.complete(Unit) } }
            @Deprecated("Deprecated in Java") override fun onError(id: String) { scope.launch {
                if (id == utteranceId) utterance?.completeExceptionally(FlutterError("tts_failure", null, null))
            } }
        })
        androidx.core.content.ContextCompat.registerReceiver(context, object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) { stop() }
        }, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
    }
    private fun installedVoices() = system.voices.orEmpty().filter {
        !it.isNetworkConnectionRequired && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features.orEmpty()
    }
    suspend fun voices(): List<String> { ready.await(); return installedVoices().map { it.locale.toLanguageTag() } }
    private fun activate() {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener({ change -> if (change < 0) stop() }, Handler(Looper.getMainLooper())).build()
        if (audio.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) problem("audio_interrupted")
        focus = request
        try { active(true) } catch (error: Exception) { audio.abandonAudioFocusRequest(request); focus = null; throw error }
    }
    fun stop() {
        generation++
        job?.cancel(); voice.cancel(); pcm?.stop(); pcm = null
        player?.release(); player = null; system.stop(); utterance?.cancel(); utterance = null; utteranceId = null
        focus?.let { audio.abandonAudioFocusRequest(it) }; focus = null; active(false)
    }
    suspend fun speak(text: String, language: String, neural: Boolean) {
        stop()
        if (text.isBlank()) return
        val request = generation
        job = scope.async {
            activate()
            try {
                if (neural) voice.synthesize(text, language) { rate -> PcmOutput(rate).also { pcm = it } }
                else {
                    ready.await()
                    val available = installedVoices().filter { languageCode(it.locale.toLanguageTag()) == languageCode(language) }
                    val selected = available.maxByOrNull { it.quality } ?: problem("tts_voice_missing")
                    system.voice = selected
                    utterance = CompletableDeferred(); utteranceId = UUID.randomUUID().toString()
                    if (system.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId) != TextToSpeech.SUCCESS) problem("tts_failure")
                    utterance!!.await()
                }
            } finally {
                if (generation == request) {
                    pcm?.stop(); pcm = null; focus?.let { audio.abandonAudioFocusRequest(it) }; focus = null; active(false)
                }
            }
        }
        job!!.await()
    }
    fun play(file: File, start: Double, end: Double?) {
        if (!start.isFinite() || start < 0 || end?.let { !it.isFinite() || it < start } == true) problem("invalid_audio_range")
        stop()
        val request = generation
        job = scope.async {
            activate()
            val media = MediaPlayer(); player = media
            try {
                media.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                val prepared = CompletableDeferred<Unit>(); val finished = CompletableDeferred<Unit>()
                media.setOnPreparedListener { prepared.complete(Unit) }
                media.setOnCompletionListener { finished.complete(Unit) }
                media.setOnErrorListener { _, _, _ ->
                    val error = FlutterError("audio_playback_failed", null, null)
                    prepared.completeExceptionally(error); finished.completeExceptionally(error); true
                }
                media.setDataSource(file.path); media.prepareAsync(); prepared.await()
                val seek = CompletableDeferred<Unit>(); media.setOnSeekCompleteListener { seek.complete(Unit) }
                media.seekTo((start * 1000).toLong(), MediaPlayer.SEEK_CLOSEST); seek.await(); media.start()
                if (end == null) finished.await() else withTimeoutOrNull(((end - start) * 1000).toLong().coerceAtLeast(1)) { finished.await() }
            } finally {
                if (player === media) { media.release(); player = null }
                if (generation == request) { focus?.let { audio.abandonAudioFocusRequest(it) }; focus = null; active(false) }
            }
        }
    }
}
