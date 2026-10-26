package io.github.yehudazakesh.chavruta_android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * מנוע ה-Flutter שמריץ את המתאם, ברמת התהליך ולא ברמת המסך.
 *
 * מנוע שנוצר בתוך ה-Activity נהרס איתו, וה-Dart שבו — כלומר המתאם כולו —
 * נעצר. כאן הוא נוצר פעם אחת ונשמר במטמון; המסך רק מתחבר אליו, ו-
 * [CompanionService] יכול להקים אותו גם בלי מסך בכלל.
 */
object CompanionEngine {
    const val ID = "companion"
    private const val CHANNEL = "chavruta/native"

    fun ensure(context: Context, by: String): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        DiagLog.write(app, "התהליך עלה; מנוע המתאם נוצר על ידי $by")
        val engine = FlutterEngine(app)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "filesDir" -> result.success(app.filesDir.absolutePath)
                    "deviceName" -> result.success(deviceName(app))
                    "startService" -> {
                        CompanionService.start(app)
                        result.success(true)
                    }
                    "stopService" -> {
                        CompanionService.stop(app)
                        result.success(true)
                    }
                    "setStatus" -> {
                        CompanionService.setStatus(call.argument<String>("text") ?: "")
                        result.success(true)
                    }
                    "launchedAtBoot" -> result.success(Prefs.takeLaunchedAtBoot())
                    "getStartOnBoot" -> result.success(Prefs.startOnBoot(app))
                    "setStartOnBoot" -> {
                        Prefs.setStartOnBoot(app, call.argument<Boolean>("enabled") == true)
                        result.success(Prefs.startOnBoot(app))
                    }
                    "isBatteryExempt" -> result.success(isBatteryExempt(app))
                    "requestBatteryExempt" -> {
                        result.success(requestBatteryExempt(app))
                    }
                    "openUri" -> result.success(openUri(app, call.argument<String>("uri") ?: ""))
                    else -> result.notImplemented()
                }
            }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }

    /** השם שהמשתמש נתן לטלפון בהגדרות, ואם אין — יצרן ודגם. */
    private fun deviceName(context: Context): String {
        if (Build.VERSION.SDK_INT >= 25) {
            val named = Settings.Global.getString(
                context.contentResolver,
                Settings.Global.DEVICE_NAME
            )
            if (!named.isNullOrBlank()) return named
        }
        return "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    }

    /**
     * פותח קישור `otzaria://` — כך המתאם מבקש מאוצריא להתקין את התוסף.
     * `false` = אין אפליקציה שמטפלת בקישור, כלומר אוצריא אינה מותקנת.
     */
    private fun openUri(context: Context, uri: String): Boolean = try {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (e: Exception) {
        false
    }

    private fun isBatteryExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * מבקש מהמשתמש לפטור את המתאם מחיסכון בסוללה — חלון מערכת שהוא מאשר
     * בעצמו. בלי הפטור חלק מהטלפונים עוצרים את המתאם ברקע גם עם שירות חזית.
     */
    private fun requestBatteryExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return false
        return try {
            context.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }
}
