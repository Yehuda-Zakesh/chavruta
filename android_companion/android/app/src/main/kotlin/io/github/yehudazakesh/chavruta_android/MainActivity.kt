package io.github.yehudazakesh.chavruta_android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * המסך מציג מנוע Flutter שחי מחוץ לו (ראו [CompanionEngine]). סגירת המסך,
 * או החלקה שלו מרשימת האפליקציות האחרונות, אינה עוצרת את המתאם — רק
 * כפתור העצירה עוצר אותו.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        CompanionEngine.ensure(applicationContext, "המסך")
        super.onCreate(savedInstanceState)
        // בלי ההרשאה שירות החזית עדיין רץ, רק בלי התראה גלויה.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun getCachedEngineId(): String = CompanionEngine.ID

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
