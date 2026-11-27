package com.eyedeadevelopment.fluttertts

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowTextToSpeech

@RunWith(RobolectricTestRunner::class)
class FlutterTtsPluginShutdownTest {
    private fun binding(): FlutterPlugin.FlutterPluginBinding {
        val binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
        `when`(binding.applicationContext).thenReturn(RuntimeEnvironment.getApplication())
        return binding
    }

    @Test
    fun detachSurvivesFailureToStartShutdownThread() {
        val plugin = FlutterTtsPlugin { _ ->
            throw OutOfMemoryError("pthread_create (1040KB stack) failed: Try again")
        }
        val binding = binding()
        plugin.onAttachedToEngine(binding)
        plugin.onDetachedFromEngine(binding)
    }

    @Test
    fun detachShutsDownAnEngineThatNeverInitializedOnANamedThread() {
        val started = mutableListOf<Thread>()
        val plugin = FlutterTtsPlugin { thread ->
            started.add(thread)
            thread.run()
        }
        val binding = binding()
        plugin.onAttachedToEngine(binding)
        val engine = ShadowTextToSpeech.getLastTextToSpeechInstance()
        plugin.onDetachedFromEngine(binding)

        assertEquals(listOf("TtsEngineShutdown"), started.map { it.name })
        assertTrue(shadowOf(engine).isShutdown)
    }

    // The no-arg constructor is the one Flutter's plugin registrant calls: it must really start the thread.
    @Test
    fun registrantConstructorShutsDownOnARealThread() {
        val plugin = FlutterTtsPlugin()
        val binding = binding()
        plugin.onAttachedToEngine(binding)
        val engine = ShadowTextToSpeech.getLastTextToSpeechInstance()
        plugin.onDetachedFromEngine(binding)

        val deadline = System.currentTimeMillis() + 5_000
        while (!shadowOf(engine).isShutdown && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue(shadowOf(engine).isShutdown)
    }
}
