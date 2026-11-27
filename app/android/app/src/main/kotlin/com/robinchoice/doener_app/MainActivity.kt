package com.robinchoice.doener_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // AES-GCM through javax.crypto, so the app ships no encryption of its own: opens a contact directory box, null when the key does not fit
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.robinchoice.doener/crypto").setMethodCallHandler { call, result ->
            if (call.method != "openAesGcm") return@setMethodCallHandler result.notImplemented()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(call.argument<ByteArray>("key"), "AES"), GCMParameterSpec(128, call.argument<ByteArray>("nonce")))
            try {
                result.success(cipher.doFinal(call.argument<ByteArray>("sealed")))
            } catch (wrongKey: AEADBadTagException) {
                result.success(null)
            }
        }
    }
}
