package com.yedu.zhupi

import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.dart.PlatformMessageHandler
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.util.ReflectionHelpers

/** Java embedding behavior only: Android native Flutter JNI and loader are test shadows. */
@Implements(value = FlutterJNI::class, callThroughByDefault = false)
class FlutterJniShadow {
    private var attached = false
    var handler: PlatformMessageHandler? = null
    val replies = mutableMapOf<Int, ByteArray?>()
    val dispatched = mutableListOf<String>()
    var entrypointHandlers: Set<String> = emptySet()

    @Implementation
    fun setPlatformMessageHandler(value: PlatformMessageHandler?) {
        handler = value
    }

    @Implementation
    fun invokePlatformMessageResponseCallback(id: Int, message: ByteBuffer, position: Int) {
        val copy = message.duplicate()
        copy.flip()
        val bytes = ByteArray(copy.remaining())
        copy.get(bytes)
        replies[id] = bytes
    }

    @Implementation
    fun invokePlatformMessageEmptyResponseCallback(id: Int) {
        replies[id] = null
    }

    @Implementation
    fun dispatchPlatformMessage(
        channel: String,
        message: ByteBuffer,
        position: Int,
        responseId: Int,
    ) {
        dispatched.add(channel)
    }

    @Implementation
    fun runBundleAndSnapshotFromLibrary(
        bundle: String,
        entrypoint: String?,
        path: String?,
        assets: android.content.res.AssetManager,
        args: List<String>?,
        id: Long,
    ) {
        entrypointHandlers =
            ReflectionHelpers.getField<Map<String, Any>>(handler, "messageHandlers").keys.toSet()
    }

    @Implementation fun isAttached(): Boolean = attached

    @Implementation
    fun attachToNative() {
        attached = true
    }

    @Implementation
    fun detachFromNativeAndReleaseResources() {
        attached = false
    }
}

@Implements(value = FlutterLoader::class, callThroughByDefault = false)
class FlutterLoaderShadow {
    @Implementation fun initialized(): Boolean = true

    @Implementation fun findAppBundlePath(): String = "flutter_assets"
}

@RunWith(RobolectricTestRunner::class)
@Config(
    manifest = Config.NONE,
    sdk = [35],
    shadows = [FlutterJniShadow::class, FlutterLoaderShadow::class],
    instrumentedPackages = ["io.flutter"],
)
class EngineRetentionTest {
    private fun jni(engine: FlutterEngine): FlutterJniShadow =
        Shadow.extract(ReflectionHelpers.getField<FlutterJNI>(engine, "flutterJNI"))

    private fun invoke(engine: FlutterEngine, method: String): Any? {
        val shadow = jni(engine)
        val encoded = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, null))
        encoded.flip()
        shadow.replies.remove(17)
        shadow.handler!!.handleMessageFromDart("thusfar/paths", encoded, 17, 0)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("Method channel must reply", shadow.replies.containsKey(17))
        val bytes = shadow.replies[17] ?: fail("Method is missing")
        return StandardMethodCodec.INSTANCE.decodeEnvelope(ByteBuffer.wrap(bytes as ByteArray))
    }

    @After
    fun resetHost() {
        val field = ProcessingEngineHost::class.java.getDeclaredField("engine")
        field.isAccessible = true
        (field.get(null) as FlutterEngine?)?.destroy()
        field.set(null, null)
        ProcessingEngineHost.requestNotificationPermission = null
    }

    @Test
    fun requiredChannelsExistBeforeDartEntrypointStarts() {
        val app = RuntimeEnvironment.getApplication()
        val engine = ProcessingEngineHost.get(app)
        assertTrue(
            jni(engine)
                .entrypointHandlers
                .containsAll(setOf("thusfar/paths", "thusfar/processing_notifications"))
        )
        assertEquals(app.filesDir.absolutePath, invoke(engine, "filesDir"))
    }

    @Test
    fun replacedImportOwnerSurvivesOldHostDetachment() {
        val engine = ProcessingEngineHost.get(RuntimeEnvironment.getApplication())
        val oldOwner = Any()
        val newOwner = Any()
        ProcessingEngineHost.attachImports(oldOwner) { listOf(mapOf("name" to "old")) }
        ProcessingEngineHost.attachImports(newOwner) { listOf(mapOf("name" to "new")) }
        ProcessingEngineHost.detachImports(oldOwner)
        assertEquals(listOf(mapOf("name" to "new")), invoke(engine, "takeImports"))
        val before = jni(engine).dispatched.size
        ProcessingEngineHost.importsAvailable(oldOwner)
        assertEquals(before, jni(engine).dispatched.size)
        ProcessingEngineHost.importsAvailable(newOwner)
        assertEquals(before + 1, jni(engine).dispatched.size)
        ProcessingEngineHost.detachImports(newOwner)
        assertEquals(emptyList<Any>(), invoke(engine, "takeImports"))
    }

    @Test
    fun multipleActivityHostsReuseOneAppOwnedEngine() {
        val app = RuntimeEnvironment.getApplication()
        val engine = ProcessingEngineHost.get(app)
        val first = MainActivity()
        assertSame(engine, first.provideFlutterEngine(app))
        assertFalse(first.shouldDestroyEngineWithHost())
        val replacement = MainActivity()
        assertSame(engine, replacement.provideFlutterEngine(app))
        assertFalse(replacement.shouldDestroyEngineWithHost())
        assertSame(engine, ProcessingEngineHost.get(app))
    }
}
