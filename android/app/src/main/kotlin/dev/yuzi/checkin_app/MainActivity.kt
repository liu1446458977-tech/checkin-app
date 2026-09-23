package dev.yuzi.checkin_app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 比默认的 FlutterActivity 多两条通道：
 *
 * 1) export —— 数据导出。调起系统「另存为」(ACTION_CREATE_DOCUMENT) 让用户选目录，
 *    不需要任何存储权限（Android 10+ 分区存储下直接写公共 Download 会被拒）。
 * 2) secure —— API Key 的安全存储。用 AndroidKeyStore 里的 AES/GCM 密钥加密，
 *    密文存 SharedPreferences。密钥由系统密钥库托管、不出硬件，明文永不落盘。
 *    没有引入 flutter_secure_storage 插件，是为了不动 AGP9 那套脆弱的构建配置。
 *
 * 这里刻意只用 android.app.Activity / android.security.keystore 这类平台 API，
 * 不依赖 androidx.activity 版本，避免再引入新的构建变量。
 */
class MainActivity : FlutterActivity() {

    // ---------- 导出 ----------
    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    // ---------- 安全存储 ----------
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, MODE_PRIVATE) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXPORT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveText" -> handleSaveText(
                        call.argument("name"), call.argument("mime"),
                        call.argument("content"), result
                    )
                    else -> result.notImplemented()
                }
            }

        // ---------- 每日提醒（替代 workmanager，见 Reminders.kt） ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMINDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        val hour = (call.argument<Int>("hour") ?: 22).coerceIn(0, 23)
                        Reminders.setEnabled(this, true)
                        Reminders.schedule(this, hour)
                        result.success(true)
                    }
                    "cancel" -> {
                        Reminders.cancel(this)
                        result.success(true)
                    }
                    // App 在前台把「今天还剩几项没完成」推过来，闹钟响时用它拼文案
                    "setUndone" -> {
                        Reminders.setUndone(
                            this,
                            call.argument<Int>("count") ?: 0,
                            call.argument<String>("date") ?: ""
                        )
                        result.success(true)
                    }
                    "status" -> result.success(Reminders.canNotify(this))
                    "requestPermission" -> result.success(requestNotifPermission())
                    "test" -> {
                        Reminders.notify(this, "每日打卡", "这是一条测试提醒，看到它说明提醒没问题。")
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val key = call.argument<String>("key")
                when (call.method) {
                    "available" -> result.success(isKeystoreUsable())
                    "put" -> {
                        val value = call.argument<String>("value")
                        if (key == null || value == null) {
                            result.error("BAD_ARGS", "key/value 不能为空", null)
                        } else {
                            try {
                                prefs.edit().putString(key, encrypt(value)).apply()
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("ENCRYPT_FAIL", e.toString(), null)
                            }
                        }
                    }
                    "get" -> {
                        if (key == null) {
                            result.error("BAD_ARGS", "key 不能为空", null)
                        } else {
                            try {
                                result.success(decrypt(prefs.getString(key, null)))
                            } catch (e: Exception) {
                                // 解密失败（例如换了设备 / 密钥被清除）：当作没有值，让用户重填
                                result.success(null)
                            }
                        }
                    }
                    "delete" -> {
                        if (key == null) {
                            result.error("BAD_ARGS", "key 不能为空", null)
                        } else {
                            prefs.edit().remove(key).apply()
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ================= 安全存储实现 =================

    private fun isKeystoreUsable(): Boolean = try {
        secretKey(); true
    } catch (e: Exception) {
        false
    }

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) return existing.secretKey
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        // 格式：base64(iv) + ":" + base64(ciphertext)
        return Base64.encodeToString(iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(body, Base64.NO_WRAP)
    }

    private fun decrypt(stored: String?): String? {
        if (stored.isNullOrEmpty()) return null
        val parts = stored.split(":")
        if (parts.size != 2) return null
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val body = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(body), Charsets.UTF_8)
    }

    // ================= 导出实现 =================

    private fun handleSaveText(
        name: String?,
        mime: String?,
        content: String?,
        result: MethodChannel.Result,
    ) {
        if (pendingResult != null) {
            result.error("BUSY", "已有一次导出正在进行", null)
            return
        }
        pendingResult = result
        pendingBytes = (content ?: "").toByteArray(Charsets.UTF_8)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, name ?: "checkin-export.txt")
        }
        try {
            startActivityForResult(intent, REQ_SAVE)
        } catch (e: Exception) {
            pendingResult = null
            pendingBytes = null
            result.error("NO_PICKER", e.toString(), null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_SAVE) {
            val result = pendingResult
            val bytes = pendingBytes
            pendingResult = null
            pendingBytes = null
            if (result == null) return
            val uri: Uri? = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null) // 用户取消
                return
            }
            try {
                openStream(uri)?.use { it.write(bytes ?: ByteArray(0)) }
                result.success(uri.toString())
            } catch (e: Exception) {
                result.error("WRITE_FAIL", e.toString(), null)
            }
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * Android 13+ 才需要动态申请通知权限。
     * 返回"当前是否已经可以发通知"；被拒时返回 false，由设置页引导用户去系统设置里开。
     */
    private fun requestNotifPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
        return false
    }

    private fun openStream(uri: Uri): OutputStream? = contentResolver.openOutputStream(uri)

    companion object {
        private const val EXPORT_CHANNEL = "dev.yuzi.checkin_app/export"
        private const val SECURE_CHANNEL = "dev.yuzi.checkin_app/secure"
        private const val REMINDER_CHANNEL = "dev.yuzi.checkin_app/reminders"
        private const val REQ_SAVE = 4711
        private const val REQ_NOTIF = 4713
        private const val PREFS_NAME = "checkin_secrets"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "checkin_master_key_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }
}
