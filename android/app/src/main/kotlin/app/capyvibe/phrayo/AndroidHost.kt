package app.capyvibe.phrayo

import android.content.*
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.UUID

internal class AndroidHost private constructor(val context: Context) : PhrayoNative {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    var activity = WeakReference<MainActivity>(null)
    var events: PhrayoEvents? = null
    private val files = AudioFiles(context)
    private val secrets = SecretStore(context)
    private val preferences = context.getSharedPreferences("configuration", Context.MODE_PRIVATE)
    private val gate = InferenceGate()
    private val offline = OfflineSpeech(context, gate)
    private val translation = LocalTranslation()
    private val voice = VoiceRuntime(context, gate, scope)
    private var playbackActive = false
    private val playback = SpeechPlayback(context, scope, voice) { active -> playbackActive = active; updateService() }
    private var session: SessionMessage? = null
    private var capture: AudioCapture? = null
    private var packets: Channel<Packet>? = null
    private var packetTask: Job? = null
    private var cloud: SonioxStream? = null
    private var stopTask: Deferred<SessionMessage>? = null
    private var drainTask: Deferred<Unit>? = null
    private var cancelling = false
    private var starting = false
    private var source = "zh-CN"
    private var target = "en-US"
    private var localOnly = false
    private var provider = "soniox"
    private var terms = emptyList<String>()
    private var mossJob: JSONObject? = null
    private val exports = Mutex()
    private var speculative: Job? = null
    private var speechChoice: Pair<String, Boolean>? = null
    private val transcriptionJobs = mutableMapOf<String, Job>()
    private data class Packet(val data: ByteArray, val seconds: Double, val level: Double)
    val recording get() = session?.state in setOf("recording", "paused")
    val paused get() = session?.state == "paused"
    private val busy get() = session?.state in setOf("recording", "paused", "processing") || starting || cancelling || stopTask?.isActive == true
    private fun emit(persist: Boolean = true) {
        val value = session ?: return
        if (persist && value.state != "cancelled") files.save(value)
        scope.launch { runCatching { events?.sessionChanged(value) } }
    }
    private fun updateService() { MediaSessionService.update(context, recording, paused, playbackActive) }
    override suspend fun start(kind: String, source: String, target: String, localOnly: Boolean,
        sttProvider: String, transcriptionTerms: List<String>): SessionMessage {
        if (kind !in setOf("recording", "speaking", "shortcut", "practice")) problem("invalid_session")
        if (recording && !cancelling && stopTask?.isActive != true &&
            (session?.kind == kind || kind in setOf("speaking", "shortcut") && session?.kind in setOf("speaking", "shortcut"))) return session!!
        if (busy) problem("recording_active")
        val selectedTerms = vocabulary(transcriptionTerms)
        starting = true
        try { (activity.get() ?: problem("open_app")).requireMicrophone() } finally { starting = false }
        stopPlayback(); gate.recording.value = true
        scope.launch { voice.cancelPreparation() }
        this.source = source; this.target = target; this.localOnly = localOnly; provider = sttProvider; terms = selectedTerms
        val id = UUID.randomUUID().toString()
        session = SessionMessage(id = id, kind = kind, state = "recording", seconds = 0.0, level = 0.0,
            transcript = "", translation = "", segments = emptyList(), sourceLanguage = source, targetLanguage = target)
        stopTask = null; drainTask = null
        mossJob = if (!localOnly && sttProvider == "mossPro" && kind != "recording") JSONObject()
            .put("provider", "mossPro").put("recordingId", id).put("revision", 0).put("stage", "pending")
            .put("model", "moss-transcribe-diarize-pro").put("transcriptionTerms", JSONArray(terms)) else null
        try {
            persistMoss(); updateService()
            if (!localOnly && sttProvider == "soniox" && kind != "recording") {
                secrets.read("soniox")?.takeIf(String::isNotBlank)?.let { key ->
                    cloud = SonioxStream(key, source, target, terms) { result -> scope.launch {
                        if (session?.id == id && !cancelling && session?.state in setOf("recording", "processing")) {
                            session = session!!.copy(transcript = result.text, translation = result.translation, segments = result.segments)
                            emit(false)
                        }
                    } }
                }
            }
            val channel = Channel<Packet>(64); packets = channel
            var journalTime = 0.0; var lastVoice = 0.0; var heardVoice = false
            packetTask = scope.launch {
                for (packet in channel) {
                    if (session?.id != id || cancelling || session?.state != "recording") continue
                    session = session!!.copy(seconds = packet.seconds, level = (packet.level * 8).coerceAtMost(1.0))
                    cloud?.append(packet.data)
                    if (packet.level > 0.012) { heardVoice = true; lastVoice = packet.seconds }
                    val persist = packet.seconds - journalTime >= 1
                    if (persist) journalTime = packet.seconds
                    emit(persist)
                    if (kind != "recording" && packet.seconds >= 60 || kind == "shortcut" && heardVoice && packet.seconds - lastVoice >= 1.5) {
                        scope.launch { stop() }
                    } else if (kind == "shortcut" && !heardVoice && packet.seconds >= 10) scope.launch { cancel() }
                }
            }
            capture = AudioCapture(files.folder(id), { data, seconds, level ->
                if (channel.trySend(Packet(data, seconds, level)).isFailure) scope.launch { interrupt("audio_interrupted") }
            }, { code -> scope.launch { interrupt(code) } }).also { it.start() }
            emit(); return session!!
        } catch (error: Exception) {
            drain(); cloud?.cancel(); cloud = null; gate.recording.value = false
            session = session!!.copy(state = "interrupted", error = errorCode(error), path = "$id/recording.m4a")
            emit(); updateService(); throw error
        }
    }
    private suspend fun drain() {
        if (drainTask == null) drainTask = scope.async {
            capture?.finish(); capture = null
            packets?.close(); packetTask?.join(); packets = null; packetTask = null
            gate.recording.value = false
        }
        drainTask!!.await()
    }
    override suspend fun stop(): SessionMessage {
        stopTask?.let { return it.await() }
        val current = session ?: problem("no_recording")
        if (!recording) return current
        stopTask = scope.async {
            drain()
            if (cancelling) return@async session!!
            session = session!!.copy(state = "processing", level = 0.0, path = "${current.id}/recording.m4a")
            emit(); updateService()
            try {
                val output = ensureAudio(session!!.path!!)
                if (current.kind != "recording") {
                    if (!localOnly && provider == "mossPro") {
                        val moss = MossTranscription(secrets.read("moss")?.takeIf(String::isNotBlank) ?: problem("moss_missing"))
                        val result = moss.run(output, mossJob!!) { persistMoss() }
                        session = session!!.copy(segments = result, transcript = result.joinToString(" ") { it.text })
                    } else {
                        val result = try { cloud?.finish() ?: throw FlutterError("use_local", null, null) }
                        catch (error: Exception) {
                            currentCoroutineContext().ensureActive(); cloud?.cancel()
                            val segments = offline.transcribe(output, source)
                            if (terms.isNotEmpty()) session = session!!.copy(error = "vocabulary_unavailable")
                            SpeechResult(segments.joinToString(" ") { it.text }, "", segments)
                        }
                        session = session!!.copy(transcript = result.text, translation = result.translation, segments = result.segments)
                    }
                    if (session!!.transcript.isBlank()) problem("no_speech")
                }
                mossJob?.put("stage", "cleanup")
                session = session!!.copy(state = "saved"); persistMoss()
                mossJob?.let { job ->
                    runCatching { MossTranscription(secrets.read("moss") ?: problem("moss_missing")).cleanup(job) }
                        .onSuccess { mossJob = null; persistMoss() }
                }
            } catch (error: Exception) {
                if (!cancelling || mossJob != null) {
                    session = session!!.copy(state = "interrupted", error = if (error is CancellationException) "audio_interrupted" else errorCode(error))
                    persistMoss()
                }
            } finally { cloud?.cancel(); cloud = null }
            if (!cancelling) emit()
            session!!
        }
        return stopTask!!.await()
    }
    private fun persistMoss() { session = session?.copy(sttJobJson = mossJob?.toString()); session?.let(files::save) }
    override suspend fun pause() {
        if (session?.kind != "recording" || !recording) return
        capture?.pause(true); session = session!!.copy(state = "paused", level = 0.0); emit(); updateService()
    }
    override suspend fun resume() {
        if (!paused) return
        capture?.pause(false); session = session!!.copy(state = "recording"); emit(); updateService()
    }
    override suspend fun cancel() {
        if (cancelling) return
        cancelling = true
        try {
            cloud?.cancel(); cloud = null
            stopTask?.cancel(); drain(); stopTask?.join()
            val current = session ?: return
            if (mossJob?.optString("stage") !in setOf(null, "pending")) {
                session = current.copy(state = "interrupted", level = 0.0, error = "audio_interrupted")
                persistMoss(); emit()
            } else {
                withContext(Dispatchers.IO) { files.folder(current.id).deleteRecursively() }
                session = current.copy(state = "cancelled", level = 0.0, transcript = "", translation = "", segments = emptyList(), path = null, error = null, sttJobJson = null)
                mossJob = null; emit(false)
            }
            stopTask = null
        } finally { cancelling = false; gate.recording.value = false; updateService() }
    }
    suspend fun interrupt(code: String) {
        if (!recording || cancelling) return
        drain(); cloud?.cancel(); cloud = null
        session = session!!.copy(state = "interrupted", level = 0.0, error = code, path = "${session!!.id}/recording.m4a")
        emit(); updateService()
    }
    override fun snapshot() = session
    override fun recover() = files.recover().filter { !busy || it.id != session?.id }
    override fun acknowledge(id: String) { if (busy && session?.id == id) problem("recording_active"); files.acknowledge(id) }
    override suspend fun translate(text: String, source: String, target: String) = translation.translate(text, source, target)
    private suspend fun ensureAudio(path: String): File = exports.withLock { AudioCodec.ensureAudio(files.audio(path)) }
    override suspend fun transcribe(path: String, source: String, transcriptionTerms: List<String>): List<SegmentMessage> {
        vocabulary(transcriptionTerms)
        val job = currentCoroutineContext().job
        transcriptionJobs[path] = job
        try { return offline.transcribe(ensureAudio(path), source) }
        finally { if (transcriptionJobs[path] === job) transcriptionJobs.remove(path) }
    }
    fun cancelTranscription(path: String) { transcriptionJobs[path]?.cancel() }
    override suspend fun capabilities(source: String, target: String, transcriptionTerms: List<String>) = CapabilityMessage(
        speechStatus = offline.status(source), vocabularySupported = false, speechLanguages = offline.supported(),
        installedSpeechLanguages = if (offline.store.installed()) offline.supported() else emptyList(),
        voices = playback.voices(), translationStatus = translation.status(source, target))
    override suspend fun prepareLanguages(source: String, target: String, transcriptionTerms: List<String>) {
        vocabulary(transcriptionTerms); offline.prepare(source); translation.prepare(source, target)
    }
    override suspend fun prepareTts(languages: List<String>) {
        if (languages.none(voice::supported)) problem("tts_voice_missing")
        try { voice.prepare { value -> scope.launch { runCatching { events?.ttsProgress(value) } } } }
        finally { runCatching { events?.ttsProgress(null) } }
    }
    override suspend fun ttsStatus(language: String): String {
        if (voice.supported(language)) return voice.status(language)
        return if (playback.voices().any { languageCode(it) == languageCode(language) }) "system" else "unavailable"
    }
    override suspend fun cancelTts() { voice.cancelPreparation() }
    override suspend fun previewTts(language: String, neural: Boolean) {
        if (busy) problem("recording_active")
        cancelSpeechPreparation(); playback.speak(VoiceRuntime.sample(language), language, neural)
    }
    override suspend fun prepareSpeech(text: String, language: String) {
        cancelSpeechPreparation()
        if (busy || text.isBlank()) return
        val selected = voice.status(language) == "ready"
        speechChoice = "$language\u0000$text" to selected
        if (!selected) return
        val preparation = scope.async { voice.synthesize(text, language) }
        speculative = preparation
        preparation.await()
    }
    override fun cancelSpeechPreparation() { speculative?.cancel(); speculative = null; voice.cancel(); speechChoice = null }
    override suspend fun speak(text: String, language: String) {
        if (busy) problem("recording_active")
        val selected = speechChoice?.takeIf { it.first == "$language\u0000$text" }?.second ?: (voice.status(language) == "ready")
        cancelSpeechPreparation(); playback.speak(text, language, selected)
    }
    override fun play(path: String, start: Double, end: Double?) {
        if (busy) problem("recording_active")
        cancelSpeechPreparation(); playback.play(files.audio(path), start, end)
    }
    override fun stopPlayback() { cancelSpeechPreparation(); playback.stop() }
    override fun saveSecret(service: String, value: String) = secrets.save(service, value)
    override fun readSecret(service: String) = secrets.read(service)
    override fun configure(source: String, target: String, localOnly: Boolean, sttProvider: String, transcriptionTerms: List<String>) {
        preferences.edit().putString("source", source).putString("target", target).putBoolean("localOnly", localOnly)
            .putString("provider", sttProvider).putString("terms", JSONArray(vocabulary(transcriptionTerms)).toString()).apply()
    }
    suspend fun startShortcut() = start("shortcut", preferences.getString("source", "zh-CN")!!,
        preferences.getString("target", "en-US")!!, preferences.getBoolean("localOnly", false), preferences.getString("provider", "soniox")!!,
        JSONArray(preferences.getString("terms", "[]")).let { values -> (0 until values.length()).map(values::getString) })
    override suspend fun prepareAudio(path: String) = ensureAudio(path).path
    private fun uri(file: File): Uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    private fun present(intent: Intent) { (activity.get() ?: problem("open_app")).startActivity(Intent.createChooser(intent, null)) }
    override suspend fun share(text: String, path: String?) {
        val file = path?.let { ensureAudio(it) }
        present(Intent(Intent.ACTION_SEND).apply {
            type = if (file == null) "text/plain" else "audio/mp4"
            putExtra(Intent.EXTRA_TEXT, text)
            file?.let { val resource = uri(it); putExtra(Intent.EXTRA_STREAM, resource); clipData = ClipData.newRawUri("Audio", resource); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        })
    }
    override suspend fun shareRecordings(paths: List<String>) {
        if (paths.isEmpty()) return
        val resources = ArrayList<Uri>()
        paths.distinct().forEach { resources.add(uri(ensureAudio(it))) }
        present(Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "audio/mp4"; putParcelableArrayListExtra(Intent.EXTRA_STREAM, resources)
            clipData = ClipData.newRawUri("Audio", resources.first()).also { clip -> resources.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }
    override fun deleteAudio(path: String) {
        val file = files.audio(path)
        if (busy && file.parentFile!!.name == session?.id) problem("recording_active")
        if (transcriptionJobs[path]?.isActive == true || exports.isLocked) problem("recording_active")
        stopPlayback()
        if (file.parentFile!!.exists() && !file.parentFile!!.deleteRecursively()) problem("audio_save_failed")
    }
    override fun openSettings() { (activity.get() ?: problem("open_app")).startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }
    fun trimMemory() { voice.trim() }
    companion object {
        @Volatile private var instance: AndroidHost? = null
        fun get(context: Context): AndroidHost = instance ?: synchronized(this) { instance ?: AndroidHost(context.applicationContext).also { instance = it } }
        fun errorCode(error: Exception) = (error as? FlutterError)?.code ?: "audio_save_failed"
    }
}
