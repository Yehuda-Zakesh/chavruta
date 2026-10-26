package io.github.yehudazakesh.chavruta_android

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * רישום אירועי מחזור החיים של התהליך (שירות, מנוע, עלייה) **לאותו קובץ
 * יומן** שהמתאם כותב אליו מה-Dart.
 *
 * אלה בדיוק האירועים שקורים כשאין Dart חי — התהליך נהרג, השירות הוקם
 * מחדש — ובלי הרישום הזה "לא נמצא מתאם" אינו אומר דבר: אי אפשר לדעת אם
 * המתאם מת, לא קם, או חי ולא נמצא.
 */
object DiagLog {
    private val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)

    fun write(context: Context, message: String) {
        try {
            val dir = File(context.filesDir, "Chavruta")
            dir.mkdirs()
            File(dir, "companion.log")
                .appendText("[${format.format(Date())}] [אנדרואיד] $message\n")
        } catch (e: Exception) {
            // היומן הוא כלי אבחון; כישלון בו אינו נוגע לסנכרון.
        }
    }
}
