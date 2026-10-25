package io.github.yehudazakesh.chavruta_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder

/**
 * שירות החזית שמחזיק את המתאם חי — **והוא גם הבעלים של המנוע**.
 *
 * כשאוצריא בחזית, אנדרואיד (14 ומעלה) מקפיא תוך שניות אפליקציה שירדה
 * לרקע; שירות חזית עם התראה קבועה הוא הדרך המוצהרת לומר שהעבודה נמשכת.
 *
 * בהרבה טלפונים החלקת האפליקציה מרשימת האחרונות הורגת את **כל** התהליך,
 * גם כשיש שירות חזית. לכן השירות מוגדר `START_STICKY` ומקים בעצמו את
 * מנוע ה-Flutter ב-[onCreate]: כשהמערכת מקימה אותו מחדש, המתאם עולה איתו
 * בלי שאיש פתח את המסך. כך גם בעלייה עם הטלפון ([BootReceiver]).
 */
class CompanionService : Service() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            val notification = buildNotification(status)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // המערכת אינה מתירה כאן שירות חזית (הקמה מחדש מהרקע בגרסאות
            // מסוימות). מתאם בלי שירות חזית היה מוקפא בכל מקרה, ולכן עדיף
            // לא לעלות בכלל מאשר לעלות ולשתוק.
            DiagLog.write(this, "המערכת לא התירה שירות חזית, השירות לא עלה: $e")
            stopSelf()
            return
        }
        DiagLog.write(this, "שירות החזית עלה")
        instance = this
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager?
        multicastLock = wifi?.createMulticastLock("chavruta")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        CompanionEngine.ensure(applicationContext, "השירות")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // `intent == null` = המערכת הקימה את השירות מחדש אחרי שהתהליך נהרג.
        if (intent == null) DiagLog.write(this, "השירות הוקם מחדש על ידי המערכת")
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        DiagLog.write(this, "האפליקציה הוחלקה מרשימת האחרונות; השירות ממשיך")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DiagLog.write(this, "השירות נעצר")
        if (instance === this) instance = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "מתאם חברותא",
                    NotificationManager.IMPORTANCE_MIN
                )
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("מתאם חברותא")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_chavruta)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun showStatus(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val CHANNEL_ID = "companion"
        private const val NOTIFICATION_ID = 1

        private var instance: CompanionService? = null
        private var status = "פועל"

        val isRunning: Boolean get() = instance != null

        fun start(context: Context) {
            // שירות שכבר רץ אינו צריך הפעלה, וקריאה ל-startForegroundService
            // מהרקע (כשהמתאם התעורר בלי מסך) עלולה להיחסם.
            if (isRunning) return
            val intent = Intent(context, CompanionService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CompanionService::class.java))
        }

        /** משנה את שורת ההתראה: "מסנכרן" / "ממתין לאוצריא". */
        fun setStatus(text: String) {
            status = text
            instance?.showStatus(text)
        }
    }
}
