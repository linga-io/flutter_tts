package com.eyedeadevelopment.fluttertts

import android.content.ContentValues
import android.content.ContentResolver
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.Locale
import java.util.MissingResourceException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors


/** FlutterTtsPlugin  */
class FlutterTtsPlugin : MethodCallHandler, FlutterPlugin {
    private data class PendingMethodCall(
        val call: MethodCall,
        val result: Result
    )

    private data class SpeechRequest(
        val text: String,
        val clientUtteranceId: String?,
        val awaitCompletion: Boolean,
        val focusRequested: Boolean,
        val isContinuation: Boolean,
        var awaitedResult: Result?
    )

    private data class SynthesisRequest(
        var awaitedResult: Result?
    )

    private data class SynthesisOutput(
        val resolver: ContentResolver,
        val mediaStoreUri: Uri,
        val parcelFileDescriptor: ParcelFileDescriptor? = null,
        val temporaryFile: File? = null
    )

    private data class SynthesisFinalization(
        val succeeded: Boolean,
        val publishedOutput: SynthesisOutput? = null
    )

    private var handler: Handler? = null
    private var methodChannel: MethodChannel? = null
    private var awaitSpeakCompletion = false
    private var awaitSynthCompletion = false
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private val tag = "TTS"
    private val pendingMethodCalls = ArrayList<PendingMethodCall>()
    private val speechRequests = ConcurrentHashMap<String, SpeechRequest>()
    private val synthesisRequests = ConcurrentHashMap<String, SynthesisRequest>()
    private val synthesisOutputs = ConcurrentHashMap<String, SynthesisOutput>()
    private var synthesisIoExecutor: ExecutorService? = null
    private var bundle: Bundle? = null
    private var silencems = 0
    private var lastProgress = 0
    private var pauseText: String? = null
    private var pausedClientUtteranceId: String? = null
    private var pausedAwaitedResult: Result? = null
    private var isPaused: Boolean = false
    private var activeSpeechUtteranceId: String? = null
    private var lastSubmittedSpeechUtteranceId: String? = null
    private var queueMode: Int = TextToSpeech.QUEUE_FLUSH
    private var ttsStatus: Int? = null
    private var engineResult: Result? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { /* no-op */ }
    private var audioFocusOwnerUtteranceId: String? = null
    @Volatile private var lifecycleGeneration = 0
    @Volatile private var detached = false

    companion object {
        private const val SILENCE_PREFIX = "SIL_"
        private const val SYNTHESIZE_TO_FILE_PREFIX = "STF_"
    }

    private enum class SpeakStatus {
        SUCCESS,
        RETRY_AFTER_INIT,
        FAILURE
    }

    private fun initInstance(messenger: BinaryMessenger, context: Context) {
        detached = false
        lifecycleGeneration += 1
        val generation = lifecycleGeneration
        this.context = context
        methodChannel = MethodChannel(messenger, "flutter_tts")
        methodChannel!!.setMethodCallHandler(this)
        handler = Handler(Looper.getMainLooper())
        synthesisIoExecutor = Executors.newSingleThreadExecutor()
        bundle = Bundle()
        ttsStatus = null
        try {
            tts = TextToSpeech(context, createOnInitListener(false, generation))
        } catch (error: Exception) {
            tts = null
            ttsStatus = TextToSpeech.ERROR
            Log.e(tag, "Failed to create TextToSpeech engine", error)
        }
    }

    /** Android Plugin APIs  */
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        initInstance(binding.binaryMessenger, binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached = true
        lifecycleGeneration += 1
        tts?.stop()
        notifyLifecycleSpeechCancellations()
        cancelAllSpeechRequests(clearRequests = true)
        cancelAllSynthesisRequests(clearRequests = true)
        failPendingMethodCalls("TextToSpeech plugin detached")
        try {
            engineResult?.error("TtsCanceled", "TextToSpeech plugin detached", null)
        } catch (error: IllegalStateException) {
            Log.d(tag, "Engine result was already completed: ${error.message}")
        }
        engineResult = null
        discardAllSynthesisOutputs()
        synthesisIoExecutor?.shutdownNow()
        synthesisIoExecutor = null
        releaseAudioFocus()
        audioFocusRequest = null
        audioManager = null
        tts?.shutdown()
        tts = null
        ttsStatus = null
        context = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        handler?.removeCallbacksAndMessages(null)
        handler = null
    }

    private val utteranceProgressListener: UtteranceProgressListener =
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) {
                dispatchUtteranceCallback { handleUtteranceStart(utteranceId) }
            }

            override fun onDone(utteranceId: String) {
                dispatchUtteranceCallback { handleUtteranceDone(utteranceId) }
            }

            override fun onStop(utteranceId: String, interrupted: Boolean) {
                dispatchUtteranceCallback {
                    handleUtteranceStop(utteranceId, interrupted)
                }
            }

            // Requires Android 26 or later
            override fun onRangeStart(utteranceId: String, startAt: Int, endAt: Int, frame: Int) {
                super.onRangeStart(utteranceId, startAt, endAt, frame)
                dispatchUtteranceCallback {
                    handleUtteranceProgress(utteranceId, startAt, endAt)
                }
            }

            @Suppress("OVERRIDE_DEPRECATION")
            override fun onError(utteranceId: String) {
                dispatchUtteranceCallback {
                    handleUtteranceError(utteranceId, "Error from TextToSpeech")
                }
            }

            override fun onError(utteranceId: String, errorCode: Int) {
                dispatchUtteranceCallback {
                    handleUtteranceError(utteranceId, "Error from TextToSpeech - $errorCode")
                }
            }
        }

    private fun dispatchUtteranceCallback(callback: () -> Unit) {
        val mainHandler = handler ?: return
        mainHandler.post {
            if (!detached) {
                callback()
            }
        }
    }

    private fun handleUtteranceStart(utteranceId: String) {
        if (utteranceId.startsWith(SILENCE_PREFIX)) return
        if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
            if (synthesisRequests.containsKey(utteranceId)) {
                invokeMethod("synth.onStart", true)
            }
            return
        }
        val request = speechRequests[utteranceId] ?: return
        activeSpeechUtteranceId = utteranceId
        Log.d(tag, "Utterance ID has started: $utteranceId")
        if (request.isContinuation) {
            isPaused = false
            invokeMethod("speak.onContinue", speechEventArguments(request))
        } else {
            lastProgress = 0
            invokeMethod("speak.onStart", speechEventArguments(request))
        }
    }

    private fun handleUtteranceDone(utteranceId: String) {
        if (utteranceId.startsWith(SILENCE_PREFIX)) return
        if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
            if (!synthesisRequests.containsKey(utteranceId)) return
            val output = synthesisOutputs[utteranceId]
            if (output?.temporaryFile != null) {
                finalizeCopiedSynthesisOutput(utteranceId)
            } else {
                completeSynthesisRequest(
                    utteranceId,
                    finalizeSynthesisOutput(utteranceId, publish = true)
                )
            }
            return
        }
        val request = speechRequests.remove(utteranceId) ?: return
        val ownedPauseState = ownsPauseState(utteranceId)
        resolveSpeechResult(request, 1)
        Log.d(tag, "Utterance ID has completed: $utteranceId")
        invokeMethod("speak.onComplete", speechEventArguments(request))
        clearSpeechRequestPointers(utteranceId)
        if (ownedPauseState) clearPauseState()
        if (request.focusRequested) releaseAudioFocus(utteranceId)
    }

    private fun handleUtteranceStop(utteranceId: String, interrupted: Boolean) {
        if (utteranceId.startsWith(SILENCE_PREFIX)) return
        Log.d(tag, "Utterance ID has been stopped: $utteranceId. Interrupted: $interrupted")
        if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
            val request = synthesisRequests.remove(utteranceId) ?: return
            finalizeSynthesisOutput(utteranceId, publish = false)
            resolveResult(request.awaitedResult, 0)
            request.awaitedResult = null
            invokeMethod("synth.onError", "Synthesize to file was stopped")
            return
        }
        val request = speechRequests.remove(utteranceId) ?: return
        val ownedPauseState = ownsPauseState(utteranceId)
        resolveSpeechResult(request, 0)
        invokeMethod("speak.onCancel", speechEventArguments(request))
        clearSpeechRequestPointers(utteranceId)
        if (ownedPauseState) clearPauseState()
        if (request.focusRequested) releaseAudioFocus(utteranceId)
    }

    private fun handleUtteranceProgress(utteranceId: String, startAt: Int, endAt: Int) {
        if (utteranceId.startsWith(SILENCE_PREFIX) ||
            utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)
        ) return
        val request = speechRequests[utteranceId] ?: return
        val safeStart = startAt.coerceIn(0, request.text.length)
        val safeEnd = endAt.coerceIn(safeStart, request.text.length)
        if (safeEnd <= safeStart) return
        if (ownsPauseState(utteranceId)) {
            lastProgress = safeStart
        }
        val data = HashMap<String, String>()
        data["text"] = request.text
        data["start"] = safeStart.toString()
        data["end"] = safeEnd.toString()
        data["word"] = request.text.substring(safeStart, safeEnd)
        request.clientUtteranceId?.let { data["utteranceId"] = it }
        invokeMethod("speak.onProgress", data)
    }

    private fun handleUtteranceError(utteranceId: String, error: String) {
        if (utteranceId.startsWith(SILENCE_PREFIX)) return
        if (utteranceId.startsWith(SYNTHESIZE_TO_FILE_PREFIX)) {
            val request = synthesisRequests.remove(utteranceId) ?: return
            finalizeSynthesisOutput(utteranceId, publish = false)
            resolveResult(request.awaitedResult, 0)
            request.awaitedResult = null
            invokeMethod("synth.onError", "$error (synth)")
            return
        }
        val request = speechRequests.remove(utteranceId) ?: return
        val ownedPauseState = ownsPauseState(utteranceId)
        resolveSpeechResult(request, 0)
        invokeMethod("speak.onError", speechErrorArguments(request, "$error (speak)"))
        clearSpeechRequestPointers(utteranceId)
        if (ownedPauseState) clearPauseState()
        if (request.focusRequested) releaseAudioFocus(utteranceId)
    }

    private fun speechEventArguments(request: SpeechRequest): Any {
        return speechEventArguments(request.clientUtteranceId)
    }

    private fun speechEventArguments(clientUtteranceId: String?): Any {
        return clientUtteranceId?.let {
            hashMapOf<String, Any>("utteranceId" to it, "value" to true)
        } ?: true
    }

    private fun speechErrorArguments(request: SpeechRequest, message: String): Any {
        return request.clientUtteranceId?.let {
            hashMapOf<String, Any>("utteranceId" to it, "message" to message)
        } ?: message
    }

    private fun ownsPauseState(utteranceId: String): Boolean {
        return if (queueMode == TextToSpeech.QUEUE_ADD) {
            activeSpeechUtteranceId == utteranceId ||
                (activeSpeechUtteranceId == null &&
                    lastSubmittedSpeechUtteranceId == utteranceId)
        } else {
            lastSubmittedSpeechUtteranceId == utteranceId ||
                (lastSubmittedSpeechUtteranceId == null &&
                    activeSpeechUtteranceId == utteranceId)
        }
    }

    private fun clearSpeechRequestPointers(utteranceId: String) {
        if (activeSpeechUtteranceId == utteranceId) activeSpeechUtteranceId = null
        if (lastSubmittedSpeechUtteranceId == utteranceId) {
            lastSubmittedSpeechUtteranceId = null
        }
    }

    private fun resolveResult(result: Result?, value: Any) {
        if (result == null) return
        try {
            result.success(value)
        } catch (error: IllegalStateException) {
            Log.d(tag, "Result was already completed: ${error.message}")
        }
    }

    private fun resolveAcceptedSpeechResult(
        result: Result?,
        clientUtteranceId: String?,
        value: Int
    ) {
        val nativeValue: Any = clientUtteranceId?.let {
            hashMapOf<String, Any>("accepted" to true, "value" to value)
        } ?: value
        resolveResult(result, nativeValue)
    }

    private fun resolveSpeechResult(request: SpeechRequest, value: Int) {
        if (request.awaitCompletion) {
            resolveAcceptedSpeechResult(
                request.awaitedResult,
                request.clientUtteranceId,
                value
            )
        }
        request.awaitedResult = null
    }

    private fun resolvePausedSpeechResult(value: Int) {
        resolveAcceptedSpeechResult(
            pausedAwaitedResult,
            pausedClientUtteranceId,
            value
        )
        pausedAwaitedResult = null
    }

    private fun pauseSpeechRequest(utteranceId: String) {
        val request = speechRequests.remove(utteranceId) ?: return
        invokeMethod("speak.onPause", speechEventArguments(request))
        clearSpeechRequestPointers(utteranceId)
        if (request.focusRequested) releaseAudioFocus(utteranceId)
    }

    private fun cancelSpeechRequests(utteranceIds: Collection<String>) {
        for (utteranceId in utteranceIds) {
            val request = speechRequests.remove(utteranceId) ?: continue
            resolveSpeechResult(request, 0)
            invokeMethod("speak.onCancel", speechEventArguments(request))
            clearSpeechRequestPointers(utteranceId)
            if (request.focusRequested) releaseAudioFocus(utteranceId)
        }
    }

    private fun cancelSynthesisRequests(utteranceIds: Collection<String>) {
        for (utteranceId in utteranceIds) {
            val request = synthesisRequests.remove(utteranceId) ?: continue
            finalizeSynthesisOutput(utteranceId, publish = false)
            resolveResult(request.awaitedResult, 0)
            request.awaitedResult = null
            invokeMethod("synth.onError", "Synthesize to file was stopped")
        }
    }

    private fun cancelAllSpeechRequests(clearRequests: Boolean) {
        for (request in speechRequests.values) {
            resolveSpeechResult(request, 0)
        }
        resolvePausedSpeechResult(0)
        if (clearRequests) {
            speechRequests.clear()
            activeSpeechUtteranceId = null
            lastSubmittedSpeechUtteranceId = null
            clearPauseState()
        }
    }

    private fun notifyLifecycleSpeechCancellations() {
        val clientUtteranceIds = speechRequests.values
            .mapNotNull { it.clientUtteranceId }
            .toMutableSet()
        pausedClientUtteranceId?.let { clientUtteranceIds.add(it) }
        for (clientUtteranceId in clientUtteranceIds) {
            methodChannel?.invokeMethod(
                "speak.onCancel",
                speechEventArguments(clientUtteranceId)
            )
        }
        val hasLegacyRequest = speechRequests.values.any {
            it.clientUtteranceId == null
        } || (isPaused && pausedClientUtteranceId == null)
        if (hasLegacyRequest) {
            methodChannel?.invokeMethod("speak.onCancel", true)
        }
    }

    private fun cancelPausedSpeechOwnership() {
        if (!isPaused) return
        val pausedToken = pausedClientUtteranceId
        val matchingRequestIds = speechRequests.entries
            .filter { (_, request) ->
                request.isContinuation && request.clientUtteranceId == pausedToken
            }
            .map { it.key }

        for (utteranceId in matchingRequestIds) {
            val request = speechRequests.remove(utteranceId) ?: continue
            resolveSpeechResult(request, 0)
            clearSpeechRequestPointers(utteranceId)
            if (request.focusRequested) releaseAudioFocus(utteranceId)
        }
        resolvePausedSpeechResult(0)
        invokeMethod("speak.onCancel", speechEventArguments(pausedToken))
    }

    private fun cancelAllSynthesisRequests(clearRequests: Boolean) {
        for (request in synthesisRequests.values) {
            resolveResult(request.awaitedResult, 0)
            request.awaitedResult = null
        }
        if (clearRequests) synthesisRequests.clear()
    }

    private fun clearPauseState() {
        isPaused = false
        lastProgress = 0
        pauseText = null
        pausedClientUtteranceId = null
        pausedAwaitedResult = null
    }

    private fun drainPendingMethodCalls() {
        val pendingCalls = synchronized(this@FlutterTtsPlugin) {
            val calls = pendingMethodCalls.toList()
            pendingMethodCalls.clear()
            calls
        }
        for (pendingCall in pendingCalls) {
            onMethodCall(pendingCall.call, pendingCall.result)
        }
    }

    private fun failPendingMethodCalls(message: String) {
        val pendingCalls = synchronized(this@FlutterTtsPlugin) {
            val calls = pendingMethodCalls.toList()
            pendingMethodCalls.clear()
            calls
        }
        for (pendingCall in pendingCalls) {
            try {
                pendingCall.result.error("TtsError", message, null)
            } catch (error: IllegalStateException) {
                Log.d(tag, "Pending result was already completed: ${error.message}")
            }
        }
    }

    private fun configureSuccessfulTts() {
        val textToSpeech = tts ?: return
        textToSpeech.setOnUtteranceProgressListener(utteranceProgressListener)
        try {
            val locale: Locale = textToSpeech.defaultVoice.locale
            if (isLanguageAvailable(locale)) {
                textToSpeech.language = locale
            }
        } catch (e: NullPointerException) {
            Log.e(tag, "getDefaultLocale: " + e.message)
        } catch (e: IllegalArgumentException) {
            Log.e(tag, "getDefaultLocale: " + e.message)
        }
    }

    private fun createOnInitListener(
        reportResult: Boolean,
        generation: Int
    ): TextToSpeech.OnInitListener {
        return TextToSpeech.OnInitListener { status ->
            val mainHandler = handler ?: return@OnInitListener
            mainHandler.post {
                if (detached || generation != lifecycleGeneration) return@post
                ttsStatus = status
                if (status == TextToSpeech.SUCCESS) {
                    configureSuccessfulTts()
                    if (reportResult) resolveResult(engineResult, 1)
                    engineResult = null
                    drainPendingMethodCalls()
                } else {
                    val message = "Failed to initialize TextToSpeech with status: $status"
                    Log.e(tag, message)
                    if (reportResult) {
                        try {
                            engineResult?.error("TtsError", message, null)
                        } catch (error: IllegalStateException) {
                            Log.d(tag, "Engine result was already completed: ${error.message}")
                        }
                    }
                    engineResult = null
                    failPendingMethodCalls(message)
                }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (detached) {
            result.error("TtsError", "TextToSpeech plugin is detached", null)
            return
        }
        // If TTS is still loading
        synchronized(this@FlutterTtsPlugin) {
            if (ttsStatus == null) {
                // Suspend method call until the TTS engine is ready
                pendingMethodCalls.add(PendingMethodCall(call, result))
                return
            }
        }
        if (ttsStatus != TextToSpeech.SUCCESS && call.method != "setEngine") {
            result.error("TtsError", "TextToSpeech engine is not initialized", ttsStatus)
            return
        }
        when (call.method) {
            "speak" -> {
                val requestedText: String? = call.argument("text")
                val focus: Boolean = call.argument("focus") ?: false
                val rawClientUtteranceId: Any? = call.argument("utteranceId")
                val requestedClientUtteranceId = when (rawClientUtteranceId) {
                    null -> null
                    is String -> rawClientUtteranceId.takeIf { it.isNotEmpty() }
                    else -> null
                }
                if (requestedText.isNullOrEmpty()) {
                    result.error(
                        "InvalidArgument",
                        "speak requires a non-empty text argument.",
                        null
                    )
                    return
                }
                if (rawClientUtteranceId != null && requestedClientUtteranceId == null) {
                    result.error(
                        "InvalidArgument",
                        "speak utteranceId must be a non-empty String.",
                        null
                    )
                    return
                }
                if (isPaused &&
                    (pauseText == null ||
                        requestedClientUtteranceId != pausedClientUtteranceId)
                ) {
                    result.success(0)
                    return
                }
                if (isPaused &&
                    speechRequests.values.any {
                        it.isContinuation &&
                            it.clientUtteranceId == requestedClientUtteranceId
                    }
                ) {
                    result.success(0)
                    return
                }
                if (!isPaused &&
                    requestedClientUtteranceId != null &&
                    speechRequests.values.any {
                        it.clientUtteranceId == requestedClientUtteranceId
                    }
                ) {
                    result.success(0)
                    return
                }

                var textToSpeak = requestedText
                var clientUtteranceId = requestedClientUtteranceId
                var inheritedResult: Result? = null
                val isContinuation = isPaused
                if (isContinuation) {
                    textToSpeak = pauseText!!
                    clientUtteranceId = pausedClientUtteranceId ?: requestedClientUtteranceId
                    inheritedResult = pausedAwaitedResult
                }

                val shouldAwaitCompletion =
                    awaitSpeakCompletion && queueMode == TextToSpeech.QUEUE_FLUSH
                val hasPendingAwaitedResult = speechRequests.values.any {
                    it.awaitedResult != null
                }
                if (!isContinuation && shouldAwaitCompletion && hasPendingAwaitedResult) {
                    result.success(0)
                    return
                }

                val requestResult = inheritedResult ?: if (shouldAwaitCompletion) result else null
                when (
                    speak(
                        textToSpeak,
                        focus,
                        clientUtteranceId,
                        shouldAwaitCompletion || inheritedResult != null,
                        isContinuation,
                        requestResult
                    )
                ) {
                    SpeakStatus.SUCCESS -> {
                        if (isContinuation) {
                            // Progress offsets for the resumed native utterance are
                            // relative to the already-sliced pauseText. Reset before
                            // another pause can reuse an offset from the original text.
                            lastProgress = 0
                        }
                        if (!isContinuation &&
                            (queueMode == TextToSpeech.QUEUE_FLUSH ||
                                speechRequests.size == 1)
                        ) {
                            clearPauseState()
                        }
                        pausedAwaitedResult = null
                        if (requestResult !== result) result.success(1)
                    }
                    SpeakStatus.RETRY_AFTER_INIT -> {
                        synchronized(this@FlutterTtsPlugin) {
                            pendingMethodCalls.add(PendingMethodCall(call, result))
                        }
                    }
                    SpeakStatus.FAILURE -> {
                        if (requestResult === result) {
                            resolveResult(result, 0)
                        } else {
                            if (inheritedResult != null) {
                                resolveAcceptedSpeechResult(
                                    inheritedResult,
                                    clientUtteranceId,
                                    0
                                )
                            } else {
                                resolveResult(requestResult, 0)
                            }
                            result.success(0)
                        }
                        if (isContinuation) {
                            invokeMethod(
                                "speak.onCancel",
                                speechEventArguments(clientUtteranceId)
                            )
                        }
                        clearPauseState()
                    }
                }
            }

            "awaitSpeakCompletion" -> {
                awaitSpeakCompletion = java.lang.Boolean.parseBoolean(call.arguments.toString())
                result.success(1)
            }

            "awaitSynthCompletion" -> {
                awaitSynthCompletion = java.lang.Boolean.parseBoolean(call.arguments.toString())
                result.success(1)
            }

            "getMaxSpeechInputLength" -> {
                val res = maxSpeechInputLength
                result.success(res)
            }

            "synthesizeToFile" -> {
                val text: String? = call.argument("text")
                if (synthesisRequests.isNotEmpty()) {
                    result.success(0)
                    return
                }
                val fileName: String? = call.argument("fileName")
                val isFullPath: Boolean = call.argument("isFullPath") ?: false
                if (text.isNullOrEmpty() ||
                    fileName.isNullOrBlank() ||
                    fileName.indexOf('\u0000') >= 0 ||
                    (!isFullPath &&
                        (fileName == "." ||
                            fileName == ".." ||
                            fileName.contains('/') ||
                            fileName.contains('\\')))
                ) {
                    result.error(
                        "InvalidArgument",
                        "synthesizeToFile requires non-empty text and a valid file name or path.",
                        null
                    )
                    return
                }
                val utteranceId = SYNTHESIZE_TO_FILE_PREFIX + UUID.randomUUID().toString()
                val shouldAwaitCompletion = awaitSynthCompletion
                synthesisRequests[utteranceId] = SynthesisRequest(
                    awaitedResult = if (shouldAwaitCompletion) result else null
                )
                val synthesizeResult = synthesizeToFile(
                    text,
                    fileName,
                    isFullPath,
                    utteranceId
                )
                if (synthesizeResult != TextToSpeech.SUCCESS) {
                    val request = synthesisRequests.remove(utteranceId)
                    if (request?.awaitedResult === result) {
                        resolveResult(result, 0)
                    } else {
                        result.success(0)
                    }
                } else if (shouldAwaitCompletion) {
                    // The latched per-request result is completed by the native callback.
                } else {
                    result.success(1)
                }
            }

            "pause" -> {
                val utteranceId = if (queueMode == TextToSpeech.QUEUE_ADD) {
                    activeSpeechUtteranceId ?: lastSubmittedSpeechUtteranceId
                } else {
                    lastSubmittedSpeechUtteranceId ?: activeSpeechUtteranceId
                }
                val request = utteranceId?.let { speechRequests[it] }
                if (request == null || isPaused) {
                    result.success(0)
                    return
                }
                isPaused = true
                val safeProgress = lastProgress.coerceIn(0, request.text.length)
                pauseText = request.text.substring(safeProgress)
                pausedClientUtteranceId = request.clientUtteranceId
                pausedAwaitedResult = request.awaitedResult
                request.awaitedResult = null
                val stopResult = stopNative()
                if (stopResult == TextToSpeech.SUCCESS) {
                    pauseSpeechRequest(utteranceId)
                    cancelSpeechRequests(speechRequests.keys.toList())
                    cancelSynthesisRequests(synthesisRequests.keys.toList())
                    result.success(1)
                } else {
                    request.awaitedResult = pausedAwaitedResult
                    pausedAwaitedResult = null
                    pauseText = null
                    pausedClientUtteranceId = null
                    isPaused = false
                    result.success(0)
                }
            }

            "stop" -> {
                val stopResult = stopNative()
                // A failed native stop is not followed by a reliable terminal
                // callback. Complete local requests so awaited Dart futures and
                // audio focus cannot remain stuck indefinitely.
                cancelPausedSpeechOwnership()
                cancelSpeechRequests(speechRequests.keys.toList())
                cancelSynthesisRequests(synthesisRequests.keys.toList())
                clearPauseState()
                releaseAudioFocus()
                result.success(if (stopResult == TextToSpeech.SUCCESS) 1 else 0)
            }

            "setEngine" -> {
                val engine = (call.arguments as? String)?.takeIf { it.isNotBlank() }
                if (engine == null) {
                    result.error(
                        "InvalidArgument",
                        "setEngine requires a non-empty String argument.",
                        null
                    )
                    return
                }
                setEngine(engine, result)
            }

            "setSpeechRate" -> {
                val rate = call.arguments.toString().toFloatOrNull()
                // To make the FlutterTts API consistent across platforms,
                // Android 1.0 is mapped to flutter 0.5.
                if (rate == null || !rate.isFinite() || rate <= 0.0f) {
                    result.success(0)
                    return
                }
                val setResult = setSpeechRate(rate * 2.0f)
                result.success(if (setResult == TextToSpeech.SUCCESS) 1 else 0)
            }

            "setVolume" -> {
                val volume = call.arguments.toString().toFloatOrNull()
                if (volume == null) {
                    result.success(0)
                    return
                }
                setVolume(volume, result)
            }

            "setPitch" -> {
                val pitch = call.arguments.toString().toFloatOrNull()
                if (pitch == null) {
                    result.success(0)
                    return
                }
                setPitch(pitch, result)
            }

            "setLanguage" -> {
                val language: String = call.arguments.toString()
                setLanguage(language, result)
            }

            "getLanguages" -> getLanguages(result)
            "getVoices" -> getVoices(result)
            "getSpeechRateValidRange" -> getSpeechRateValidRange(result)
            "getEngines" -> getEngines(result)
            "getDefaultEngine" -> getDefaultEngine(result)
            "getDefaultVoice" -> getDefaultVoice(result)
            "setVoice" -> {
                val voice: HashMap<String?, String>? = call.arguments()
                if (voice == null) {
                    result.success(0)
                    return
                }
                setVoice(voice, result)
            }

            "clearVoice" -> clearVoice(result)

            "isLanguageAvailable" -> {
                val language: String = call.arguments.toString()
                val locale: Locale = Locale.forLanguageTag(language)
                result.success(isLanguageAvailable(locale))
            }

            "setSilence" -> {
                val silencems = call.arguments.toString().toIntOrNull()
                if (silencems == null) {
                    result.success(0)
                    return
                }
                if (silencems < 0) {
                    result.success(0)
                    return
                }
                this.silencems = silencems
                result.success(1)
            }

            "setSharedInstance" -> result.success(1)
            "isLanguageInstalled" -> {
                val language: String? = call.arguments as? String
                result.success(isLanguageInstalled(language))
            }

            "areLanguagesInstalled" -> {
                val languages: List<String?>? = call.arguments()
                if (languages == null) {
                    result.success(emptyMap<String?, Boolean>())
                    return
                }
                result.success(areLanguagesInstalled(languages))
            }

            "setQueueMode" -> {
                val queueMode = call.arguments.toString().toIntOrNull()
                if (queueMode == null) {
                    result.success(0)
                    return
                }
                if (queueMode != TextToSpeech.QUEUE_FLUSH && queueMode != TextToSpeech.QUEUE_ADD) {
                    result.success(0)
                    return
                }
                this.queueMode = queueMode
                result.success(1)
            }

            "setAudioAttributesForNavigation" -> {
                setAudioAttributesForNavigation()
                result.success(1)
            }

            else -> result.notImplemented()
        }
    }

    private fun setSpeechRate(rate: Float): Int =
        tts?.setSpeechRate(rate) ?: TextToSpeech.ERROR

    private fun isLanguageAvailable(locale: Locale?): Boolean {
        return tts!!.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE
    }

    private fun areLanguagesInstalled(languages: List<String?>): Map<String?, Boolean> {
        val result: MutableMap<String?, Boolean> = HashMap()
        for (language in languages) {
            result[language] = isLanguageInstalled(language)
        }
        return result
    }

    private fun isLanguageInstalled(language: String?): Boolean {
        if (language == null) return false
        val locale: Locale = Locale.forLanguageTag(language)
        if (isLanguageAvailable(locale)) {
            var voiceToCheck: Voice? = null
            for (v in tts?.voices.orEmpty()) {
                if (localeMatches(locale, v.locale) && !v.isNetworkConnectionRequired) {
                    voiceToCheck = v
                    break
                }
            }
            if (voiceToCheck != null) {
                val features: Set<String> = voiceToCheck.features
                return (!features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED))
            }
        }
        return false
    }

    private fun localeMatches(requested: Locale, candidate: Locale): Boolean {
        return requested.language.equals(candidate.language, ignoreCase = true) &&
            (requested.script.isEmpty() ||
                requested.script.equals(candidate.script, ignoreCase = true)) &&
            (requested.country.isEmpty() ||
                requested.country.equals(candidate.country, ignoreCase = true))
    }

    private fun setEngine(engine: String?, result: Result) {
        val applicationContext = context
        if (applicationContext == null || detached) {
            result.error("TtsError", "TextToSpeech plugin is detached", null)
            return
        }
        tts?.stop()
        notifyLifecycleSpeechCancellations()
        cancelAllSpeechRequests(clearRequests = true)
        cancelAllSynthesisRequests(clearRequests = true)
        discardAllSynthesisOutputs()
        releaseAudioFocus()
        tts?.shutdown()
        tts = null

        ttsStatus = null
        engineResult = result
        lifecycleGeneration += 1
        val generation = lifecycleGeneration
        try {
            tts = TextToSpeech(
                applicationContext,
                createOnInitListener(true, generation),
                engine
            )
        } catch (error: Exception) {
            ttsStatus = TextToSpeech.ERROR
            engineResult = null
            result.error("TtsError", "Failed to create TextToSpeech engine", error.message)
        }
    }

    private fun setLanguage(language: String?, result: Result) {
        if (language == null) {
            result.success(0)
            return
        }
        val locale: Locale = Locale.forLanguageTag(language)
        val setResult = tts?.setLanguage(locale) ?: TextToSpeech.LANG_NOT_SUPPORTED
        result.success(if (setResult >= TextToSpeech.LANG_AVAILABLE) 1 else 0)
    }

    private fun setVoice(voice: HashMap<String?, String>, result: Result) {
        for (ttsVoice in tts!!.voices) {
            if (ttsVoice.name == voice["name"] && ttsVoice.locale
                    .toLanguageTag() == voice["locale"]
            ) {
                val setResult = tts?.setVoice(ttsVoice) ?: TextToSpeech.ERROR
                result.success(if (setResult == TextToSpeech.SUCCESS) 1 else 0)
                return
            }
        }
        Log.d(tag, "Voice name not found: $voice")
        result.success(0)
    }

    private fun clearVoice(result: Result) {
        val textToSpeech = tts
        val defaultVoice = textToSpeech?.defaultVoice
        if (textToSpeech == null || defaultVoice == null) {
            result.success(0)
            return
        }
        val setResult = textToSpeech.setVoice(defaultVoice)
        result.success(if (setResult == TextToSpeech.SUCCESS) 1 else 0)
    }

    private fun setVolume(volume: Float, result: Result) {
        if (volume in (0.0f..1.0f)) {
            bundle!!.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, volume)
            result.success(1)
        } else {
            Log.d(tag, "Invalid volume $volume value - Range is from 0.0 to 1.0")
            result.success(0)
        }
    }

    private fun setPitch(pitch: Float, result: Result) {
        if (pitch in (0.5f..2.0f)) {
            val setResult = tts?.setPitch(pitch) ?: TextToSpeech.ERROR
            result.success(if (setResult == TextToSpeech.SUCCESS) 1 else 0)
        } else {
            Log.d(tag, "Invalid pitch $pitch value - Range is from 0.5 to 2.0")
            result.success(0)
        }
    }

    private fun getVoices(result: Result) {
        val voices = ArrayList<HashMap<String, String>>()
        try {
            for (voice in tts!!.voices) {
                val voiceMap = HashMap<String, String>()
                readVoiceProperties(voiceMap, voice)
                voices.add(voiceMap)
            }
            result.success(voices)
        } catch (e: NullPointerException) {
            Log.d(tag, "getVoices: " + e.message)
            result.success(null)
        }
    }

    private fun getLanguages(result: Result) {
        val locales = ArrayList<String>()
        try {
            // TextToSpeech.availableLanguages is implemented by speech
            // services from API 23; this plugin now requires API 24.
            for (locale in tts!!.availableLanguages) {
                locales.add(locale.toLanguageTag())
            }
        } catch (e: MissingResourceException) {
            Log.d(tag, "getLanguages: " + e.message)
        } catch (e: NullPointerException) {
            Log.d(tag, "getLanguages: " + e.message)
        }
        result.success(locales)
    }

    private fun getEngines(result: Result) {
        val engines = ArrayList<String>()
        try {
            for (engineInfo in tts!!.engines) {
                engines.add(engineInfo.name)
            }
        } catch (e: Exception) {
            Log.d(tag, "getEngines: " + e.message)
        }
        result.success(engines)
    }

    private fun getDefaultEngine(result: Result) {
        val defaultEngine: String? = tts!!.defaultEngine
        result.success(defaultEngine)
    }

    private fun getDefaultVoice(result: Result) {
        val defaultVoice: Voice? = tts!!.defaultVoice
        val voice = HashMap<String, String>()
        if (defaultVoice != null) {
            readVoiceProperties(voice, defaultVoice)
        }
        result.success(voice)
    }
    // Add voice properties into the voice map
    fun readVoiceProperties(map: MutableMap<String, String>, voice: Voice) {
        map["name"] = voice.name
        map["locale"] = voice.locale.toLanguageTag()
        map["quality"] = qualityToString(voice.quality)
        map["latency"] = latencyToString(voice.latency)
        map["network_required"] = if (voice.isNetworkConnectionRequired) "1" else "0"
        map["features"] = voice.features.joinToString(separator = "\t")

    }

    // Function to map quality integer to the constant name
    fun qualityToString(quality: Int): String {
        return when (quality) {
            Voice.QUALITY_VERY_HIGH -> "very high"
            Voice.QUALITY_HIGH -> "high"
            Voice.QUALITY_NORMAL -> "normal"
            Voice.QUALITY_LOW -> "low"
            Voice.QUALITY_VERY_LOW -> "very low"
            else -> "unknown"
        }
    }
    // Function to map latency integer to the constant name
    fun latencyToString(quality: Int): String {
        return when (quality) {
            Voice.LATENCY_VERY_HIGH -> "very high"
            Voice.LATENCY_HIGH -> "high"
            Voice.LATENCY_NORMAL -> "normal"
            Voice.LATENCY_LOW -> "low"
            Voice.LATENCY_VERY_LOW -> "very low"
            else -> "unknown"
        }
    }

    private fun getSpeechRateValidRange(result: Result) {
        // Valid values available in the android documentation.
        // https://developer.android.com/reference/android/speech/tts/TextToSpeech#setSpeechRate(float)
        // To make the FlutterTts API consistent across platforms,
        // we map Android 1.0 to flutter 0.5 and so on.
        val data = HashMap<String, String>()
        // Android accepts only positive native rates. Flutter rates are doubled
        // before being sent to Android, so expose a small usable positive lower
        // bound instead of advertising 0, which setSpeechRate rejects.
        data["min"] = "0.01"
        data["normal"] = "0.5"
        data["max"] = "1.5"
        data["platform"] = "android"
        result.success(data)
    }

    private fun speak(
        text: String,
        focus: Boolean,
        clientUtteranceId: String?,
        shouldAwaitCompletion: Boolean,
        isContinuation: Boolean,
        awaitedResult: Result?
    ): SpeakStatus {
        val uuid: String = UUID.randomUUID().toString()
        val request = SpeechRequest(
            text = text,
            clientUtteranceId = clientUtteranceId,
            awaitCompletion = shouldAwaitCompletion,
            focusRequested = focus,
            isContinuation = isContinuation,
            awaitedResult = awaitedResult
        )
        return if (isTtsReady()) {
            val requestsFlushedBySubmission =
                if (queueMode == TextToSpeech.QUEUE_FLUSH) {
                    speechRequests.keys.toList()
                } else {
                    emptyList()
                }
            val synthesesFlushedBySubmission =
                if (queueMode == TextToSpeech.QUEUE_FLUSH) {
                    synthesisRequests.keys.toList()
                } else {
                    emptyList()
            }
            speechRequests[uuid] = request
            val previousAudioFocusOwner =
                if (focus) requestAudioFocus(uuid) else null

            var queueWasFlushed = false
            val speakResult = if (silencems > 0) {
                val silenceResult = tts!!.playSilentUtterance(
                    silencems.toLong(),
                    queueMode,
                    SILENCE_PREFIX + uuid
                )
                if (silenceResult == TextToSpeech.SUCCESS) {
                    queueWasFlushed = queueMode == TextToSpeech.QUEUE_FLUSH
                    tts!!.speak(text, TextToSpeech.QUEUE_ADD, Bundle(bundle ?: Bundle()), uuid)
                } else {
                    silenceResult
                }
            } else {
                tts!!.speak(text, queueMode, Bundle(bundle ?: Bundle()), uuid).also {
                    queueWasFlushed =
                        it == TextToSpeech.SUCCESS && queueMode == TextToSpeech.QUEUE_FLUSH
                }
            }
            if (queueWasFlushed) {
                cancelSpeechRequests(requestsFlushedBySubmission)
                cancelSynthesisRequests(synthesesFlushedBySubmission)
            }
            if (speakResult == TextToSpeech.SUCCESS) {
                lastSubmittedSpeechUtteranceId = uuid
                SpeakStatus.SUCCESS
            } else {
                speechRequests.remove(uuid)
                if (focus) {
                    if (queueWasFlushed) {
                        releaseAudioFocus(uuid)
                    } else {
                        restoreAudioFocusAfterFailedTransfer(
                            uuid,
                            previousAudioFocusOwner
                        )
                    }
                }
                SpeakStatus.FAILURE
            }
        } else {
            if (ttsStatus == null) {
                SpeakStatus.RETRY_AFTER_INIT
            } else {
                SpeakStatus.FAILURE
            }
        }
    }

    private fun stopNative(): Int = tts?.stop() ?: TextToSpeech.ERROR

    private val maxSpeechInputLength: Int
        get() = TextToSpeech.getMaxSpeechInputLength()

    private fun completeSynthesisRequest(
        utteranceId: String,
        finalization: SynthesisFinalization
    ) {
        val request = synthesisRequests.remove(utteranceId)
        if (request == null) {
            finalization.publishedOutput?.let { deleteMediaStoreOutput(it) }
            return
        }
        val value = if (finalization.succeeded) 1 else 0
        resolveResult(request.awaitedResult, value)
        request.awaitedResult = null
        if (finalization.succeeded) {
            Log.d(tag, "Utterance ID has completed: $utteranceId")
            invokeMethod("synth.onComplete", true)
        } else {
            invokeMethod("synth.onError", "Failed finalizing synthesized audio file")
        }
    }

    private fun finalizeCopiedSynthesisOutput(utteranceId: String) {
        val executor = synthesisIoExecutor
        val mainHandler = handler
        val generation = lifecycleGeneration
        if (executor == null || mainHandler == null) {
            completeSynthesisRequest(
                utteranceId,
                finalizeSynthesisOutput(utteranceId, publish = false)
            )
            return
        }
        try {
            executor.execute {
                val finalization = finalizeSynthesisOutput(utteranceId, publish = true)
                val posted = mainHandler.post {
                    if (detached || generation != lifecycleGeneration) {
                        finalization.publishedOutput?.let { deleteMediaStoreOutput(it) }
                        return@post
                    }
                    completeSynthesisRequest(utteranceId, finalization)
                }
                if (!posted) {
                    // The looper is shutting down, so no callback can consume
                    // this result. Do not leave a published orphan behind.
                    finalization.publishedOutput?.let { deleteMediaStoreOutput(it) }
                }
            }
        } catch (error: RuntimeException) {
            Log.e(tag, "Failed scheduling synthesized file finalization", error)
            completeSynthesisRequest(
                utteranceId,
                finalizeSynthesisOutput(utteranceId, publish = false)
            )
        }
    }

    private fun finalizeSynthesisOutput(
        utteranceId: String,
        publish: Boolean
    ): SynthesisFinalization {
        val output = synthesisOutputs.remove(utteranceId)
            ?: return SynthesisFinalization(publish)
        var succeeded = publish

        try {
            if (publish) {
                output.parcelFileDescriptor?.close()
            } else {
                output.parcelFileDescriptor?.closeWithError(
                    "Error synthesizing TTS to file"
                )
            }
        } catch (error: Exception) {
            Log.e(tag, "Failed closing synthesize file descriptor", error)
            succeeded = false
        }

        if (succeeded && output.temporaryFile != null) {
            try {
                val outputStream = output.resolver.openOutputStream(
                    output.mediaStoreUri,
                    "w"
                ) ?: throw IllegalStateException("Unable to open MediaStore output stream")
                output.temporaryFile.inputStream().use { input ->
                    outputStream.use { stream -> input.copyTo(stream) }
                }
            } catch (error: Exception) {
                Log.e(tag, "Failed copying synthesized file into MediaStore", error)
                succeeded = false
            }
        }

        // A stop, engine switch, or detach can cancel the request while an API
        // 29 temporary file is being copied. Never publish such an output.
        if (succeeded && !synthesisRequests.containsKey(utteranceId)) {
            succeeded = false
        }

        if (succeeded) {
            succeeded = publishMediaStoreOutput(output)
        }
        if (!succeeded) {
            deleteMediaStoreOutput(output)
        }
        output.temporaryFile?.let { temporaryFile ->
            if (temporaryFile.exists() && !temporaryFile.delete()) {
                Log.w(tag, "Failed deleting temporary synthesized file: ${temporaryFile.path}")
            }
        }
        return SynthesisFinalization(
            succeeded,
            publishedOutput = output.takeIf { succeeded }
        )
    }

    private fun discardAllSynthesisOutputs() {
        for (utteranceId in synthesisOutputs.keys.toList()) {
            finalizeSynthesisOutput(utteranceId, publish = false)
        }
    }

    private fun deleteMediaStoreOutput(output: SynthesisOutput) {
        try {
            output.resolver.delete(output.mediaStoreUri, null, null)
        } catch (error: Exception) {
            Log.e(tag, "Failed deleting incomplete MediaStore output", error)
        }
    }

    private fun publishMediaStoreOutput(output: SynthesisOutput): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            val updated = output.resolver.update(
                output.mediaStoreUri,
                values,
                null,
                null
            )
            if (updated <= 0) {
                Log.e(tag, "Failed publishing synthesized MediaStore output")
                false
            } else {
                true
            }
        } catch (error: Exception) {
            Log.e(tag, "Failed publishing synthesized MediaStore output", error)
            false
        }
    }

    private fun createMediaStoreSynthesisOutput(
        fileName: String,
        utteranceId: String
    ): SynthesisOutput? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val applicationContext = context ?: return null
        val resolver = applicationContext.contentResolver
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = try {
            resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, contentValues)
        } catch (error: Exception) {
            Log.e(tag, "Failed creating MediaStore entry for file: $fileName", error)
            null
        } ?: return null

        return try {
            val output = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val parcelFileDescriptor = resolver.openFileDescriptor(uri, "w")
                    ?: throw IllegalStateException("Unable to open MediaStore file descriptor")
                SynthesisOutput(
                    resolver = resolver,
                    mediaStoreUri = uri,
                    parcelFileDescriptor = parcelFileDescriptor
                )
            } else {
                val temporaryFile = File.createTempFile(
                    "flutter_tts_$utteranceId-",
                    ".wav",
                    applicationContext.cacheDir
                )
                SynthesisOutput(
                    resolver = resolver,
                    mediaStoreUri = uri,
                    temporaryFile = temporaryFile
                )
            }
            synthesisOutputs[utteranceId] = output
            output
        } catch (error: Exception) {
            Log.e(tag, "Failed opening MediaStore output for file: $fileName", error)
            try {
                resolver.delete(uri, null, null)
            } catch (deleteError: Exception) {
                Log.e(tag, "Failed deleting unusable MediaStore entry", deleteError)
            }
            null
        }
    }

    private fun synthesizeToFile(
        text: String,
        fileName: String,
        isFullPath: Boolean,
        utteranceId: String
    ): Int {
        val fullPath: String
        val requestBundle = Bundle(bundle ?: Bundle())
        requestBundle.putString(
            TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID,
            utteranceId
        )

        val result: Int = try {
            if (isFullPath) {
                val file = File(fileName)
                fullPath = file.path

                tts!!.synthesizeToFile(text, requestBundle, file, utteranceId)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val output = createMediaStoreSynthesisOutput(fileName, utteranceId)
                    ?: return TextToSpeech.ERROR
                fullPath = output.mediaStoreUri.toString()

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    tts!!.synthesizeToFile(
                        text,
                        requestBundle,
                        output.parcelFileDescriptor!!,
                        utteranceId
                    )
                } else {
                    tts!!.synthesizeToFile(
                        text,
                        requestBundle,
                        output.temporaryFile!!,
                        utteranceId
                    )
                }
            } else {
                val musicDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                if (!musicDir.exists() && !musicDir.mkdirs()) {
                    Log.d(tag, "Failed creating public Music directory")
                    return TextToSpeech.ERROR
                }
                val file = File(musicDir, fileName)
                fullPath = file.path

                tts!!.synthesizeToFile(text, requestBundle, file, utteranceId)
            }
        } catch (e: Exception) {
            Log.d(tag, "Failed creating file : $fileName. ${e.message}")
            finalizeSynthesisOutput(utteranceId, publish = false)
            return TextToSpeech.ERROR
        }

        if (result == TextToSpeech.SUCCESS) {
            Log.d(tag, "Queued synthesis output: $fullPath")
        } else {
            Log.d(tag, "Failed creating file : $fullPath")
            finalizeSynthesisOutput(utteranceId, publish = false)
        }
        return result
    }

    private fun invokeMethod(method: String, arguments: Any) {
        val mainHandler = handler ?: return
        mainHandler.post {
            methodChannel?.invokeMethod(method, arguments)
        }
    }

    private fun isTtsReady(): Boolean {
        return tts != null && ttsStatus == TextToSpeech.SUCCESS
    }

    // Method to set AudioAttributes for navigation usage
    private fun setAudioAttributesForNavigation() {
        if (tts != null) {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            tts!!.setAudioAttributes(audioAttributes)
        }
    }

    private fun requestAudioFocus(utteranceId: String): String? {
        val manager = audioManager
            ?: (context?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.also {
                audioManager = it
            }
            ?: return null

        val previousOwner = audioFocusOwnerUtteranceId
        if (previousOwner != null) {
            audioFocusOwnerUtteranceId = utteranceId
            return previousOwner
        }

        val focusResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            )
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build()
                .also { audioFocusRequest = it }
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            )
        }
        if (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            audioFocusOwnerUtteranceId = utteranceId
        }
        return null
    }

    private fun restoreAudioFocusAfterFailedTransfer(
        failedUtteranceId: String,
        previousOwner: String?
    ) {
        if (audioFocusOwnerUtteranceId != failedUtteranceId) return
        if (previousOwner != null) {
            audioFocusOwnerUtteranceId = previousOwner
        } else {
            releaseAudioFocus(failedUtteranceId)
        }
    }

    private fun releaseAudioFocus(utteranceId: String? = null) {
        val owner = audioFocusOwnerUtteranceId ?: return
        if (utteranceId != null && owner != utteranceId) return
        val manager = audioManager
        try {
            if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { manager.abandonAudioFocusRequest(it) }
            } else if (manager != null) {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocus(audioFocusChangeListener)
            }
        } catch (error: RuntimeException) {
            Log.e(tag, "Failed to abandon audio focus", error)
        }
        audioFocusOwnerUtteranceId = null
    }
}
