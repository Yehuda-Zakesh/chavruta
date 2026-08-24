; המתקין של מתאם חברותא.
;
; המתאם הוא תוכנית קונסולה קטנה שרצה ברקע ומגשרת בין תוסף החברותא שבאוצריא
; לבין מתאם אחר ברשת המקומית. המתקין מתקין אותו, מרשם אותו לעלייה עם המשתמש,
; ומצרף את קובץ התוסף כדי שההתקנה באוצריא תהיה לחיצה אחת.
;
; מה שנרשם לעלייה הוא המשגר (ChavrutaLauncher.exe) ולא המתאם עצמו: המתאם הוא
; תוכנית קונסולה, ולכן Windows היה יוצר לו חלון שחור. המשגר הוא תוכנית
; בתת-מערכת חלונות שמפעילה את המתאם עם CREATE_NO_WINDOW, כך שחלון אינו נוצר
; כלל. הרקע המלא בראש launcher/chavruta_launcher.c.
;
; אם המשגר לא נבנה (MSVC אינו מותקן על מכונת הבנייה), המתקין נופל חזרה לרישום
; המתאם עצמו עם --hidden — מה שהיה קודם, כולל החלון ב-Windows 11.
;
; ההתקנה היא למשתמש הנוכחי ואינה דורשת UAC. היוצא מן הכלל היחיד הוא חוק חומת
; האש ל-UDP 45870, שבלעדיו Windows חוסם את הודעות החברותא: עליו מתבקשות
; הרשאות מנהל פעם אחת, בסוף ההתקנה, וסירוב אינו מכשיל אותה. ראו [Code].

#define MyAppName "מתאם חברותא"
#define MyAppPublisher "יהודה זקש"
#define MyAppURL "https://github.com/Yehuda-Zakesh/chavruta"
#define MyAppExeName "ChavrutaCompanion.exe"
#define LanPort "45870"

; הגרסה והנתיבים מגיעים מ-tool\build.ps1 דרך /D, כדי שלא יהיו שני מקומות
; שצריך לעדכן בכל שחרור.
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef DistDir
  #define DistDir "..\dist"
#endif
#ifndef PluginFile
  #define PluginFile ""
#endif
#ifndef LauncherFile
  #define LauncherFile ""
#endif

; מה שמופעל בעליית המחשב, בקיצור הדרך, ובכפתור "הפעלת המתאם עכשיו" — תמיד
; אותו דבר, ולכן מוגדר פעם אחת. עם משגר: המשגר, ו---quiet עובר דרכו אל
; המתאם. בלעדיו: המתאם עצמו עם --hidden, שינסה להסתיר את החלון בעצמו.
#if LauncherFile != ""
  #define StartExe LauncherFile
  #define StartArgs "--quiet"
#else
  #define StartExe MyAppExeName
  #define StartArgs "--hidden"
#endif

[Setup]
AppId={{7F3C1A64-9D2E-4B58-91C7-0E5A4D8B6F21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; lowest = התקנה למשתמש הנוכחי בלי UAC. מי שמריץ כמנהל יקבל התקנה לכל
; המשתמשים, ואז גם חוק חומת האש נוסף בלי בקשת הרשאות נוספת.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
DefaultDirName={autopf}\Chavruta
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#DistDir}
OutputBaseFilename=chavruta-setup-{#MyAppVersion}
SetupIconFile=..\assets\chavruta.ico
; האייקון מותקן גם לצד התוכנה, ולא רק מוטבע במתקין: המתאם הוא תוצר של
; dart compile, שאינו יודע להטביע אייקון, ולכן קיצור דרך או רשומת הסרה
; שמצביעים אליו קיבלו את סמל ברירת המחדל של Windows.
UninstallDisplayIcon={app}\chavruta.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName}

[Languages]
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "startup"; Description: "הפעלת המתאם אוטומטית עם הכניסה למחשב (מומלץ — בלעדיו הסנכרון לא יעבוד)"
; לא מוגבל להתקנת מנהל: החוק נוסף דרך בקשת הרשאות חד-פעמית (ראו [Code]).
; זה השלב שבלעדיו הכי הרבה משתמשים נשארים בלי סנכרון — הודעות החברותא הן
; תעבורה נכנסת שלא התבקשה, ו-Windows חוסם אותה כברירת מחדל.
Name: "firewall"; Description: "הוספת חוק חומת אש ל-UDP {#LanPort} (מומלץ — בלעדיו Windows עלול לחסום את החברותא)"

[Files]
Source: "{#DistDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
; האייקון, שממנו מקבלים את סמלם קיצור הדרך ורשומת ההסרה.
Source: "..\assets\chavruta.ico"; DestDir: "{app}"; Flags: ignoreversion
#if LauncherFile != ""
Source: "{#DistDir}\{#LauncherFile}"; DestDir: "{app}"; Flags: ignoreversion
#endif
#if PluginFile != ""
Source: "{#DistDir}\{#PluginFile}"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
Name: "{group}\הפעלת מתאם חברותא"; Filename: "{app}\{#StartExe}"; Parameters: "{#StartArgs}"; IconFilename: "{app}\chavruta.ico"
Name: "{group}\עצירת מתאם חברותא"; Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#MyAppExeName}"
Name: "{group}\יומן המתאם"; Filename: "{localappdata}\Chavruta\companion.log"
#if PluginFile != ""
Name: "{group}\התקנת תוסף החברותא באוצריא"; Filename: "{app}\{#PluginFile}"
#endif

[Registry]
; רישום לעלייה עם המשתמש. שם הערך נשאר ChavrutaCompanion גם כשהוא מצביע
; למשגר, כדי ששדרוג יחליף את הערך הקיים במקום להוסיף לידו שני.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ChavrutaCompanion"; ValueData: """{app}\{#StartExe}"" {#StartArgs}"; Flags: uninsdeletevalue; Tasks: startup
; ומי שמסיר את הסימון — בהתקנה או בשדרוג — מקבל הסרה בפועל. בלי השורה הזו
; ערך מהתקנה קודמת היה נשאר, ובשדרוג הוא היה ממשיך להפעיל את המתאם ישירות
; (כלומר עם חלון) גם אחרי שהמשתמש ביקש שלא יעלה בכלל.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "ChavrutaCompanion"; Flags: deletevalue; Tasks: not startup

[Run]
; חוקי חומת האש אינם כאן אלא ב-[Code]: הם דורשים הרשאות מנהל, וההתקנה
; הרגילה אינה מורמת. ראו ApplyFirewallRules.
Filename: "{app}\{#StartExe}"; Parameters: "{#StartArgs}"; Description: "הפעלת המתאם עכשיו"; Flags: nowait postinstall skipifsilent runhidden
#if PluginFile != ""
Filename: "{app}\{#PluginFile}"; Description: "התקנת תוסף החברותא באוצריא (אוצריא תיפתח)"; Flags: postinstall shellexec skipifsilent unchecked
#endif

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#MyAppExeName}"; Flags: runhidden; RunOnceId: "StopCompanion"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Chavruta Companion (UDP-In)"""; Flags: runhidden; RunOnceId: "DelFwIn"; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Chavruta Companion (UDP-Out)"""; Flags: runhidden; RunOnceId: "DelFwOut"; Check: IsAdminInstallMode

[UninstallDelete]
; הלוג נוצר בזמן ריצה ולכן אינו מנוהל על ידי המתקין. הקונפיג (קוד החברותא
; ושם המכשיר) נשאר בכוונה, כדי ששדרוג לא ידרוש זיווג מחדש.
Type: files; Name: "{localappdata}\Chavruta\companion.log"

[Code]
{ חוקי חומת האש של המתאם.

  למה כאן ולא ב-[Run]: ההתקנה היא PrivilegesRequired=lowest, כלומר בלי UAC,
  ואילו netsh דורש הרשאות מנהל. כאן עולה בקשת הרשאות אחת בלבד — כל ארבע
  הפקודות רצות בתוך cmd יחיד — ומי שמסרב מקבל התקנה תקינה בלי החוק.

  למה בכלל: הודעות החברותא מגיעות ב-UDP broadcast, כלומר תעבורה נכנסת שלא
  התבקשה, ו-Windows חוסם אותה כברירת מחדל. חלון האישור שהוא מציג במקום זה
  מסמן כברירת מחדל "רשתות פרטיות" בלבד — ורשת ביתית או נקודה חמה מסומנות
  אצלו לא פעם כ"ציבורית". להישען עליו פירושו משתמשים שהמתאם רץ אצלם ואינו
  שומע כלום. לכן profile=any.

  הפתיחה אינה מסוכנת: המתאם מקבל רק הודעות חתומות HMAC במפתח שנגזר מקוד
  החברותא, וכל השאר נזרק בשקט.

  המחיקה שלפני ההוספה: netsh add מוסיף חוק נוסף בכל הרצה, ובלעדיה כל שדרוג
  היה מותיר עוד עותק ברשימת החוקים. }
procedure ApplyFirewallRules;
var
  Exe, Cmd: String;
  ResultCode: Integer;
begin
  Exe := ExpandConstant('{app}\{#MyAppExeName}');
  Cmd :=
    '/c netsh advfirewall firewall delete rule name="Chavruta Companion (UDP-In)" >nul 2>&1' +
    ' & netsh advfirewall firewall delete rule name="Chavruta Companion (UDP-Out)" >nul 2>&1' +
    ' & netsh advfirewall firewall add rule name="Chavruta Companion (UDP-In)"' +
    ' dir=in action=allow protocol=UDP localport={#LanPort} program="' + Exe + '" profile=any' +
    ' & netsh advfirewall firewall add rule name="Chavruta Companion (UDP-Out)"' +
    ' dir=out action=allow protocol=UDP program="' + Exe + '" profile=any';

  if ShellExec('runas', ExpandConstant('{cmd}'), Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    exit;

  { סירוב לבקשת ההרשאות, או netsh שנכשל. ההתקנה תקינה, אבל ייתכן שהסנכרון
    ייחסם — ועדיף שהמשתמש ידע את זה עכשיו ולא אחרי חצי שעה של המתנה. }
  if not WizardSilent then
    MsgBox(
      'לא נוסף חוק חומת אש.' + #13#10#13#10 +
      'אם המחשבים לא ימצאו זה את זה, הריצו את המתקין שוב ואשרו את בקשת ' +
      'ההרשאות — או אשרו ידנית ל-ChavrutaCompanion.exe תעבורה נכנסת ב-UDP ' +
      '{#LanPort}, כולל ברשתות ציבוריות.',
      mbInformation, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('firewall') then
  begin
    { בהתקנה שקטה אין למי להציג בקשת הרשאות. אם היא כבר מורמת — אין בקשה
      בכלל, והחוק נוסף גם שם. }
    if IsAdmin or (not WizardSilent) then
      ApplyFirewallRules;
  end;
end;
