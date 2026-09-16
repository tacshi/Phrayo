package app.capyvibe.phrayo.voice

/** Internal qualification API; model ownership belongs to one serialized worker. */
object NativeVoice {
    init { System.loadLibrary("phrayo_cosyvoice") }
    fun interface PcmListener { fun onPcm(samples: FloatArray): Boolean }
    external fun create(model: String, voice: String, threads: Int, gpu: Boolean, cacheSlots: Int, cacheFrames: Int): Long
    external fun sampleRate(handle: Long): Int
    external fun synthesize(handle: Long, text: ByteArray, instruction: ByteArray,
        streaming: Boolean, fixedTokens: IntArray?, listener: PcmListener): Boolean
    external fun stop(handle: Long)
    external fun destroy(handle: Long)
    external fun japanese(dictionary: String, text: ByteArray): ByteArray
}
