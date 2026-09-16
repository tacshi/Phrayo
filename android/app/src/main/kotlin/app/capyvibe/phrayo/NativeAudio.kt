package app.capyvibe.phrayo

import android.media.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

internal class PcmResampler(private val inputRate: Int, private val outputRate: Int = 16000) {
    private var position = 0.0
    private var previous = 0f
    private var havePrevious = false
    fun convert(input: FloatArray): FloatArray {
        if (inputRate == outputRate) return input
        val output = ArrayList<Float>((input.size.toLong()*outputRate/inputRate+2).toInt())
        for (sample in input) {
            if (!havePrevious) { previous=sample; havePrevious=true }
            while (position < 1.0) {
                output.add(previous+(sample-previous)*position.toFloat())
                position += inputRate.toDouble()/outputRate
            }
            position -= 1.0
            previous=sample
        }
        return output.toFloatArray()
    }
}

internal class AudioCapture(private val folder: File,
    private val packet: (ByteArray, Double, Double) -> Unit,
    private val failed: (String) -> Unit) {
    private val running=AtomicBoolean(false)
    private val paused=AtomicBoolean(false)
    private var audio: AudioRecord?=null
    private var thread: Thread?=null
    private var output: FileOutputStream?=null
    private var frames=0L
    private var chunkFrames=0L
    private var chunk=0
    var rate=48000
        private set

    @Suppress("MissingPermission")
    fun start() {
        rate=listOf(48000,44100,16000).firstOrNull {
            AudioRecord.getMinBufferSize(it,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT)>0
        } ?: problem("microphone_unavailable")
        folder.mkdirs()
        writeJson(File(folder,"capture.json"),JSONObject().put("rate",rate))
        val minimum=AudioRecord.getMinBufferSize(rate,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT)
        val recorder=AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()).setBufferSizeInBytes(maxOf(minimum*2,rate/5*2)).build()
        if (recorder.state!=AudioRecord.STATE_INITIALIZED) { recorder.release(); problem("microphone_unavailable") }
        audio=recorder
        var route = recorder.routedDevice?.id
        recorder.addOnRoutingChangedListener({ routing ->
            val next = routing.routedDevice?.id
            if (route != null && next != route && running.get()) failed("audio_interrupted")
            route = next
        }, android.os.Handler(android.os.Looper.getMainLooper()))
        recorder.startRecording()
        running.set(true)
        thread=Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            val resampler=PcmResampler(rate)
            val samples=ShortArray(2048)
            try {
                while (running.get()) {
                    val count=recorder.read(samples,0,samples.size,AudioRecord.READ_BLOCKING)
                    if (!running.get()) break
                    if (count<=0) throw IllegalStateException("audio_interrupted")
                    if (paused.get()) continue
                    if (output==null || chunkFrames>=rate*30L) {
                        output?.fd?.sync(); output?.close()
                        output=FileOutputStream(File(folder,"%06d.pcm".format(chunk++)))
                        chunkFrames=0
                    }
                    val raw=ByteBuffer.allocate(count*2).order(ByteOrder.LITTLE_ENDIAN)
                    val floats=FloatArray(count)
                    var power=0.0
                    for (i in 0 until count) { raw.putShort(samples[i]); floats[i]=samples[i]/32768f; power+=floats[i]*floats[i] }
                    output!!.write(raw.array())
                    frames+=count; chunkFrames+=count
                    val down=resampler.convert(floats)
                    val bytes=ByteBuffer.allocate(down.size*2).order(ByteOrder.LITTLE_ENDIAN)
                    down.forEach { bytes.putShort((it*32767).toInt().coerceIn(-32768,32767).toShort()) }
                    packet(bytes.array(),frames.toDouble()/rate,sqrt(power/count))
                    if (recorder.activeRecordingConfiguration?.isClientSilenced==true) throw IllegalStateException("audio_interrupted")
                }
            } catch (_: Exception) { if (running.getAndSet(false)) failed("audio_interrupted") }
            finally { output?.let { runCatching { it.fd.sync(); it.close() } }; output=null }
        },"phrayo-record").apply { start() }
    }
    fun pause(value: Boolean) { paused.set(value) }
    suspend fun finish() = withContext(Dispatchers.IO) {
        running.set(false)
        audio?.let { runCatching { it.stop() } }
        thread?.join()
        thread=null
        audio?.release(); audio=null
    }
}

internal object AudioCodec {
    suspend fun ensureAudio(file: File): File = withContext(Dispatchers.IO) {
        if (file.isFile && file.length()>0) return@withContext file
        val folder=file.parentFile!!
        val chunks=folder.listFiles().orEmpty().filter { it.extension=="pcm" }.sortedBy { it.name }
        if (chunks.isEmpty()) problem("no_audio")
        val rate=JSONObject(File(folder,"capture.json").readText()).getInt("rate")
        val temporary=File(folder,"recording.m4a.partial")
        val encoder=MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val muxer=MediaMuxer(temporary.path,MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var muxerStarted=false
        var track=-1
        var frames=0L
        var wrote=false
        val info=MediaCodec.BufferInfo()
        val coroutine=currentCoroutineContext()
        fun drain(wait: Boolean): Boolean {
            val index=encoder.dequeueOutputBuffer(info,if(wait) 10000 else 0)
            if (index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                check(!muxerStarted)
                track=muxer.addTrack(encoder.outputFormat); muxer.start(); muxerStarted=true
            } else if (index>=0) {
                if (info.size>0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG==0) {
                    val buffer=encoder.getOutputBuffer(index)!!
                    buffer.position(info.offset); buffer.limit(info.offset+info.size)
                    muxer.writeSampleData(track,buffer,info); wrote=true
                }
                val end=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0
                encoder.releaseOutputBuffer(index,false)
                return end
            }
            return false
        }
        try {
            val format=MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC,rate,1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE,MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE,96000)
            }
            encoder.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE); encoder.start()
            for (chunk in chunks) chunk.inputStream().buffered().use { input ->
                while (true) {
                    coroutine.ensureActive()
                    val index=encoder.dequeueInputBuffer(10000)
                    if (index<0) { drain(false); continue }
                    val buffer=encoder.getInputBuffer(index)!!.apply { clear() }
                    val bytes=ByteArray(buffer.remaining().coerceAtMost(16384) and -2)
                    val count=input.read(bytes)
                    if (count<0) { encoder.queueInputBuffer(index,0,0,frames*1_000_000/rate,0); break }
                    buffer.put(bytes,0,count)
                    encoder.queueInputBuffer(index,0,count,frames*1_000_000/rate,0)
                    frames+=count/2
                    drain(false)
                }
            }
            while (true) {
                coroutine.ensureActive()
                val index=encoder.dequeueInputBuffer(10000)
                if (index>=0) { encoder.queueInputBuffer(index,0,0,frames*1_000_000/rate,MediaCodec.BUFFER_FLAG_END_OF_STREAM); break }
                drain(false)
            }
            while (!drain(true)) coroutine.ensureActive()
            if (!wrote) problem("no_audio")
            muxer.stop(); muxerStarted=false
        } finally {
            runCatching { encoder.stop() }; encoder.release()
            if (muxerStarted) runCatching { muxer.stop() }
            muxer.release()
        }
        coroutine.ensureActive()
        if (!temporary.renameTo(file)) problem("audio_save_failed")
        chunks.forEach { it.delete() }
        file
    }

    suspend fun decode(file: File, consume: suspend (FloatArray) -> Unit) = withContext(Dispatchers.IO) {
        val extractor=MediaExtractor()
        var decoder: MediaCodec?=null
        try {
            extractor.setDataSource(file.path)
            val track=(0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/")==true }
                ?: problem("invalid_audio_path")
            extractor.selectTrack(track)
            val format=extractor.getTrackFormat(track)
            val codec=MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            decoder=codec; codec.configure(format,null,null,0); codec.start()
            var inputDone=false
            var outputDone=false
            var channels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var resampler=PcmResampler(format.getInteger(MediaFormat.KEY_SAMPLE_RATE))
            var encoding=AudioFormat.ENCODING_PCM_16BIT
            val info=MediaCodec.BufferInfo()
            while (!outputDone) {
                currentCoroutineContext().ensureActive()
                if (!inputDone) {
                    val index=codec.dequeueInputBuffer(10000)
                    if (index>=0) {
                        val buffer=codec.getInputBuffer(index)!!.apply { clear() }
                        val count=extractor.readSampleData(buffer,0)
                        if (count<0) { codec.queueInputBuffer(index,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone=true }
                        else { codec.queueInputBuffer(index,0,count,extractor.sampleTime,0); extractor.advance() }
                    }
                }
                val index=codec.dequeueOutputBuffer(info,10000)
                if (index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output=codec.outputFormat
                    channels=output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    resampler=PcmResampler(output.getInteger(MediaFormat.KEY_SAMPLE_RATE))
                    if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding=output.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else if (index>=0) {
                    val buffer=codec.getOutputBuffer(index)!!.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset); buffer.limit(info.offset+info.size)
                    val sampleBytes=if (encoding==AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                    val mono=FloatArray(info.size/sampleBytes/channels)
                    for (i in mono.indices) {
                        var sum=0f
                        repeat(channels) { sum+=if (sampleBytes==4) buffer.float else buffer.short/32768f }
                        mono[i]=sum/channels
                    }
                    outputDone=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0
                    codec.releaseOutputBuffer(index,false)
                    if (mono.isNotEmpty()) consume(resampler.convert(mono))
                }
            }
        } finally { decoder?.let { runCatching { it.stop() }; it.release() }; extractor.release() }
    }
}
