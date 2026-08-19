import 'dart:ffi';
import 'dart:io';

typedef _GetConsoleWindowNative = IntPtr Function();
typedef _GetConsoleWindowDart = int Function();
typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

/// `SW_HIDE` של Win32.
const int _swHide = 0;

/// מסתיר את חלון הקונסולה של התהליך.
///
/// המתאם הוא תוכנית קונסולה שרצה בעליית המחשב, ולכן בלי זה המשתמש היה
/// רואה חלון שחור פתוח כל היום. Dart אינו יכול לקמפל לתת-מערכת חלונות,
/// ולכן אנחנו מסתירים את החלון בעצמנו מיד בעלייה — הפתרון היחיד שאינו
/// דורש קובץ עזר (VBS) או הרשאות מנהל.
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
