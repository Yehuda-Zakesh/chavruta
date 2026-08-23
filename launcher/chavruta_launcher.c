/*
 * משגר מתאם חברותא.
 *
 * למה זה קיים בכלל: המתאם הוא תוכנית Dart, ו-Dart מקמפל ל-exe בתת-מערכת
 * *קונסולה* בלבד. Windows יוצר את חלון הקונסולה לפני שהקוד שלנו מתחיל
 * לרוץ, ולכן מתאם שרץ בעליית המחשב היה מוצג כחלון שחור.
 *
 * ההסתרה העצמית (GetConsoleWindow + ShowWindow(SW_HIDE)) שהייתה כאן קודם
 * אינה עובדת ב-Windows 11: כשמאחסן הקונסולה הוא Windows Terminal (ברירת
 * המחדל מ-22H2 והלאה), החלון הנראה שייך לתהליך WindowsTerminal.exe, ו-
 * GetConsoleWindow מחזיר חלון-דמה מוסתר של ConPTY. כלומר הסתרנו חלון
 * שאיש לא רואה, והחלון האמיתי נשאר — עד כדי כך שסגירתו הרגה את המתאם.
 * גם FreeConsole אינו פתרון: הוא משאיר חלון Terminal ריק תלוי באוויר,
 * וכתיבה ל-stdout אחריו מפילה את Dart (קוד יציאה 255) — כנראה גם ההסבר
 * לכישלון של editbin /subsystem:windows שנוסה בעבר.
 *
 * הפתרון היחיד שעובד הוא שהתהליך ש-Windows מפעיל *לא* יהיה תוכנית
 * קונסולה. הקובץ הזה הוא אותו תהליך: תוכנית בתת-מערכת חלונות, בלי חלון
 * משל עצמה, שכל תפקידה להפעיל את ChavrutaCompanion.exe עם
 * CREATE_NO_WINDOW ולצאת מיד. עם הדגל הזה למתאם *יש* קונסולה תקינה
 * (stdout עובד, בלי הקריסות של FreeConsole) אבל חלון אינו נוצר כלל —
 * לא נוצר ולא מהבהב.
 *
 * נבנה בלי ספריית ה-CRT (ראו launcher/build.ps1): נקודת הכניסה היא
 * `start`, ואין כאן שימוש ב-memset/wcscpy וחבריהם. הקוד עצמו הוא כמה
 * קילובייטים בלי שום תלות מלבד kernel32; רוב גודלו של הקובץ הוא האייקון
 * שמוטבע בו כמשאב (launcher/chavruta_launcher.rc), והמשגר הוא שנושא
 * אותו מפני שתוצר `dart compile exe` אינו יכול.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* שם קובץ המתאם, תמיד לצד המשגר באותה תיקיית התקנה. */
static const wchar_t kCompanionName[] = L"ChavrutaCompanion.exe";

/* שורת הפקודה נבנית בגלובל ולא במחסנית: מחסנית גדולה הייתה גוררת את
 * __chkstk של ה-CRT, שאינו קיים בבנייה הזו. 32767 הוא הגבול של
 * CreateProcessW ל-lpCommandLine. */
static wchar_t g_command[32768];

/* מוסיף מלה ל-g_command ומקדם את האורך. חותך בשקט אם נגמר המקום —
 * שורת פקודה כזו ארוכה אינה תרחיש אמיתי כאן. */
static void append(const wchar_t *text, int *length) {
  const int capacity = (int)(sizeof(g_command) / sizeof(g_command[0]));
  while (*text != L'\0' && *length < capacity - 1) {
    g_command[(*length)++] = *text++;
  }
  g_command[*length] = L'\0';
}

/* מדלג על argv[0] בשורת הפקודה הגלמית, כדי שנוכל להעביר למתאם את שאר
 * הארגומנטים כמו שהם. מנותח כאן ידנית ולא ב-CommandLineToArgvW, שדורש
 * shell32 ואת ה-CRT. */
static const wchar_t *skip_program_name(const wchar_t *line) {
  if (*line == L'"') {
    line++;
    while (*line != L'\0' && *line != L'"') line++;
    if (*line == L'"') line++;
  } else {
    while (*line != L'\0' && *line != L' ' && *line != L'\t') line++;
  }
  while (*line == L' ' || *line == L'\t') line++;
  return line;
}

void __stdcall start(void) {
  wchar_t companion[MAX_PATH];
  STARTUPINFOW startup;
  PROCESS_INFORMATION process;
  const wchar_t *arguments;
  DWORD length;
  int cursor;
  int slash;
  int i;

  /* נתיב המתאם נגזר מנתיב המשגר עצמו, ולא מארגומנט ולא מתיקיית העבודה:
   * כך גם קיצור דרך שהופעל מתיקייה אחרת מוצא אותו. */
  length = GetModuleFileNameW(NULL, companion, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) ExitProcess(2);

  slash = -1;
  for (i = 0; companion[i] != L'\0'; i++) {
    if (companion[i] == L'\\' || companion[i] == L'/') slash = i;
  }
  if (slash < 0) ExitProcess(2);

  cursor = slash + 1;
  for (i = 0; kCompanionName[i] != L'\0'; i++) {
    if (cursor >= MAX_PATH - 1) ExitProcess(2);
    companion[cursor++] = kCompanionName[i];
  }
  companion[cursor] = L'\0';

  /* "<נתיב מצוטט> <הארגומנטים שלנו>". הציטוט חובה — נתיב ההתקנה מכיל
   * רווחים (Program Files, ושמות משתמש). */
  cursor = 0;
  append(L"\"", &cursor);
  append(companion, &cursor);
  append(L"\"", &cursor);
  arguments = skip_program_name(GetCommandLineW());
  if (*arguments != L'\0') {
    append(L" ", &cursor);
    append(arguments, &cursor);
  }

  /* SecureZeroMemory ולא ZeroMemory: השני מתורגם לקריאה ל-memset, שאינו
   * קיים בבנייה בלי CRT. הראשון הוא לולאה inline על מצביע volatile,
   * שהמקמפל אינו מחליף בקריאה לפונקציה. */
  SecureZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  SecureZeroMemory(&process, sizeof(process));

  if (!CreateProcessW(companion, g_command, NULL, NULL, FALSE,
                      CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
    ExitProcess(1);
  }

  /* המשגר אינו ממתין למתאם — הוא רק פתח אותו. סגירת ה-handles אינה
   * הורגת את התהליך, היא רק משחררת את ההתייחסות שלנו אליו. */
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  ExitProcess(0);
}
