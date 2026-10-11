package com.yedu.zhupi

import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Foreground system speech for the open reader; no network API or extra service. */
class ReadAloudBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "thusfar/read_aloud")
    private val main = Handler(Looper.getMainLooper())
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private var tts: TextToSpeech? = null
    private var ready = false
    private var closed = false
    private var currentId: String? = null
    private val pendingInit = mutableListOf<MethodChannel.Result>()
    private var focusRequest: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0) main.post {
            val id = currentId
            stopSpeech()
            if (id != null) emit(id, "interrupted")
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> initialize(result)
                "speak" -> {
                    val id = call.argument<String>("id")
                    val text = call.argument<String>("text")
                    val rate = call.argument<Number>("rate")?.toFloat() ?: 1f
                    val language = call.argument<String>("language") ?: "zh-CN"
                    speak(id, text, rate, language, result)
                }
                "stop" -> {
                    val id = call.argument<String>("id")
                    if (id == null || id == currentId) stopSpeech()
                    result.success(null)
                }
                "settings" -> {
                    try {
                        activity.startActivity(Intent("com.android.settings.TTS_SETTINGS"))
                    } catch (_: Exception) {
                        try {
                            activity.startActivity(Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        } catch (_: Exception) { /* Vendor has no matching settings activity. */ }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        if (ready) {
            result.success(mapOf("available" to true))
            return
        }
        pendingInit.add(result)
        if (tts != null) return
        try {
            tts = TextToSpeech(activity.applicationContext) { status -> main.post {
                if (closed) return@post
                ready = status == TextToSpeech.SUCCESS
                if (ready) {
                    tts?.setAudioAttributes(attributes)
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) { if (id != null) emit(id, "start") }
                        override fun onDone(id: String?) { if (id != null) emit(id, "done") }
                        @Deprecated("Old Android engines use this callback")
                        override fun onError(id: String?) { if (id != null) speechError(id) }
                        override fun onError(id: String?, errorCode: Int) { if (id != null) speechError(id) }
                        override fun onRangeStart(id: String?, start: Int, end: Int, frame: Int) {
                            // The new range is about to start. Only the preceding text is heard.
                            if (id != null) emit(id, "boundary", start)
                        }
                    })
                }
                val response = if (ready) mapOf("available" to true) else mapOf(
                    "available" to false,
                    "message" to "未找到可用的系统语音，请在系统设置中安装语音引擎。"
                )
                pendingInit.toList().forEach { it.success(response) }
                pendingInit.clear()
                if (!ready) {
                    tts?.shutdown()
                    tts = null
                }
            } }
        } catch (_: Exception) {
            pendingInit.toList().forEach {
                it.success(mapOf("available" to false, "message" to "系统语音暂不可用，请检查文字转语音设置。"))
            }
            pendingInit.clear()
            tts = null
        }
    }

    private fun speak(id: String?, text: String?, rate: Float, language: String, result: MethodChannel.Result) {
        val engine = tts
        if (!ready || engine == null || id.isNullOrEmpty() || text.isNullOrBlank() || text.length > 4000) {
            result.success(mapOf("accepted" to false, "message" to "系统语音尚未就绪，请重新检测。"))
            return
        }
        val locale = Locale.forLanguageTag(language)
        val support = engine.setLanguage(locale)
        if (support == TextToSpeech.LANG_MISSING_DATA || support == TextToSpeech.LANG_NOT_SUPPORTED) {
            val name = if (language.startsWith("zh")) "中文" else "所需语言的"
            result.success(mapOf("accepted" to false, "message" to "系统缺少${name}语音，请在系统语音设置中下载。"))
            return
        }
        // Prefer an installed voice. Respect the configured engine when it has
        // no offline voice for this language; the panel states network may be needed.
        engine.voices?.firstOrNull { it.locale.language == locale.language && !it.isNetworkConnectionRequired }
            ?.let { engine.voice = it }
        if (!requestFocus()) {
            result.success(mapOf("accepted" to false, "message" to "其他应用正在播放声音，请稍后再听。"))
            return
        }
        engine.setSpeechRate(if (rate.isFinite()) rate.coerceIn(.5f, 2f) else 1f)
        currentId = id
        val accepted = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS
        if (!accepted) stopSpeech()
        result.success(if (accepted) mapOf("accepted" to true) else mapOf(
            "accepted" to false, "message" to "系统语音未能播放，请检查语音数据后重试。"
        ))
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(focusListener, main)
                .build().also { focusRequest = it }
            return audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        return audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun speechError(id: String) = emit(id, "error", message = "朗读中断了，请检查系统语音后重试。")

    private fun emit(id: String, type: String, offset: Int = 0, message: String? = null) {
        main.post {
            if (!closed) channel.invokeMethod("event", mapOf(
                "id" to id, "type" to type, "offset" to offset, "message" to message
            ))
        }
    }

    @Suppress("DEPRECATION")
    private fun stopSpeech() {
        currentId = null
        tts?.stop()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        } else audio.abandonAudioFocus(focusListener)
    }

    fun pause() {
        val id = currentId
        stopSpeech()
        if (id != null) emit(id, "interrupted")
    }

    fun dispose() {
        closed = true
        stopSpeech()
        tts?.shutdown()
        tts = null
        pendingInit.toList().forEach { it.success(mapOf("available" to false)) }
        pendingInit.clear()
        channel.setMethodCallHandler(null)
    }
}
