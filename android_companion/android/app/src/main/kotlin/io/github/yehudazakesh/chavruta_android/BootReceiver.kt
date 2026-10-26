package io.github.yehudazakesh.chavruta_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * עלייה עם הטלפון, ואחרי עדכון של האפליקציה — המקבילה של "עולה עם המחשב".
 *
 * המתאם עולה ומיד נכנס למצב שינה עד שאוצריא תחפש אותו (ראו
 * `CompanionRunner` בצד ה-Dart), ולכן העלייה אינה עולה כמעט דבר.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                DiagLog.write(
                    context,
                    if (intent.action == Intent.ACTION_BOOT_COMPLETED) "הטלפון עלה"
                    else "האפליקציה עודכנה"
                )
                if (Prefs.startOnBoot(context)) {
                    Prefs.setLaunchedAtBoot(true)
                    CompanionService.start(context)
                }
            }
        }
    }
}

/** העדפות שצד ה-Kotlin צריך לפני שה-Dart עלה. */
object Prefs {
    private const val FILE = "chavruta"
    private const val START_ON_BOOT = "startOnBoot"

    /** האם התהליך הנוכחי הוקם בעלייה עם הטלפון. נקרא פעם אחת מה-Dart. */
    private var launchedAtBoot = false

    fun startOnBoot(context: Context): Boolean =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getBoolean(START_ON_BOOT, true)

    fun setStartOnBoot(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(START_ON_BOOT, enabled)
            .apply()
    }

    fun setLaunchedAtBoot(value: Boolean) {
        launchedAtBoot = value
    }

    fun takeLaunchedAtBoot(): Boolean {
        val value = launchedAtBoot
        launchedAtBoot = false
        return value
    }
}
