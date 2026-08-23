import 'dart:ffi';
import 'dart:io';

typedef _GetConsoleWindowNative = IntPtr Function();
typedef _GetConsoleWindowDart = int Function();
typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

/// `SW_HIDE` של Win32.
const int _swHide = 0;

/// מנסה להסתיר את חלון הקונסולה של התהליך. רשת ביטחון, לא הפתרון.
///
/// **הפתרון לחלון השחור הוא `ChavrutaLauncher.exe`** — תוכנית זעירה
/// בתת-מערכת חלונות שמפעילה את המתאם עם `CREATE_NO_WINDOW`, כך שחלון
/// אינו נוצר כלל. היא מה שרשום לעלייה עם המחשב, והרקע המלא בראש
/// `launcher/chavruta_launcher.c`.
///
/// הפונקציה הזו נשארת בגלל הרצה ישירה של ה-exe (לחיצה כפולה, קיצור דרך
/// ישן): שם כן נוצר חלון. חשוב לדעת שהיא מצליחה רק כשמאחסן הקונסולה הוא
/// conhost הקלאסי. ב-Windows 11, שבו Windows Terminal הוא ברירת המחדל
/// מ-22H2, החלון הנראה שייך לתהליך `WindowsTerminal.exe` ו-
/// `GetConsoleWindow` מחזיר חלון-דמה מוסתר של ConPTY — כלומר אנחנו
/// מסתירים חלון שאיש לא רואה, והחלון האמיתי נשאר (עד כדי כך שסגירתו
/// הורגת את המתאם). נמדד: `WindowsTerminal` עם `MainWindowHandle` תקין,
/// מול `MainWindowHandle = 0` בתהליך המתאם עצמו.
///
/// מה שנוסה ונפסל, כדי שלא ינוסה שוב:
/// - `editbin /subsystem:windows` — ה-exe קורס בעלייה (קוד 255, בלי אף
///   שורת לוג).
/// - `FreeConsole()` — משאיר חלון Terminal ריק תלוי באוויר, וכתיבה ל-
///   `stdout` אחריו מפילה את Dart באותו קוד 255. עם `CREATE_NO_WINDOW`
///   יש למתאם קונסולה תקינה, ולכן שם הבעיה הזו אינה קיימת.
///
/// `bin/chavruta_companion.dart` קורא לפונקציה הזו כברירת מחדל, אלא אם
/// המשתמש מבקש `--console` לצפייה חיה בלוג בפיתוח.
///
/// אינה עושה כלום מחוץ ל-Windows, וכשלון בה אינו עוצר את המתאם.
void hideConsoleWindow() {
  if (!Platform.isWindows) return;
  try {
    final getConsoleWindow = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GetConsoleWindowNative, _GetConsoleWindowDart>(
          'GetConsoleWindow',
        );
    final showWindow = DynamicLibrary.open('user32.dll')
        .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');

    final handle = getConsoleWindow();
    if (handle != 0) showWindow(handle, _swHide);
  } catch (_) {
    // אין קונסולה, או שהקריאה נחסמה. אין מה לעשות עם זה — וגם אין צורך:
    // הפונקציה נועדה לנוחות בלבד.
  }
}
