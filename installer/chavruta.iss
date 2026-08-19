; המתקין של מתאם חברותא.
;
; המתאם הוא תוכנית קונסולה קטנה שרצה ברקע ומגשרת בין תוסף החברותא שבאוצריא
; לבין מתאם אחר ברשת המקומית. המתקין מתקין אותו, מרשם אותו לעלייה עם המשתמש
; (עם --hidden, כדי שלא ייראה חלון), ומצרף את קובץ התוסף כדי שההתקנה באוצריא
; תהיה לחיצה אחת.
;
; ההתקנה היא למשתמש הנוכחי ואינה דורשת UAC. כשמריצים את המתקין כמנהל, הוא
; מוסיף גם חוק חומת אש ל-UDP 45870; אחרת Windows יציג את בקשת האישור הרגילה
; בפעם הראשונה שהמתאם מאזין לרשת.

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
; המשתמשים, ואז גם חוק חומת האש נוסף אוטומטית.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
DefaultDirName={autopf}\Chavruta
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#DistDir}
OutputBaseFilename=chavruta-setup-{#MyAppVersion}
SetupIconFile=chavruta.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName}

[Languages]
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "startup"; Description: "הפעלת המתאם אוטומטית עם הכניסה למחשב (מומלץ — בלעדיו הסנכרון לא יעבוד)"
Name: "firewall"; Description: "הוספת חוק חומת אש ל-UDP {#LanPort} (דורש הרשאות מנהל)"; Check: IsAdminInstallMode

[Files]
Source: "{#DistDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
#if PluginFile != ""
Source: "{#DistDir}\{#PluginFile}"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
Name: "{group}\הפעלת מתאם חברותא"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--hidden"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{group}\עצירת מתאם חברותא"; Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#MyAppExeName}"
Name: "{group}\יומן המתאם"; Filename: "{localappdata}\Chavruta\companion.log"
#if PluginFile != ""
Name: "{group}\התקנת תוסף החברותא באוצריא"; Filename: "{app}\{#PluginFile}"
#endif

[Registry]
; רישום לעלייה עם המשתמש. --hidden מסתיר את חלון הקונסולה של המתאם.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ChavrutaCompanion"; ValueData: """{app}\{#MyAppExeName}"" --hidden"; Flags: uninsdeletevalue; Tasks: startup

[Run]
; חוק חומת אש לתעבורת ה-broadcast של המתאם. רק בהתקנת מנהל — בהתקנה
; למשתמש בודד Windows ישאל את המשתמש בפעם הראשונה, וזה מספיק.
;
; profile=any ולא private בלבד: נקודה חמה שמחשב או טלפון משתף מסומנת אצל
; Windows כרשת ציבורית לא מעט פעמים, וזה תרחיש השימוש המרכזי. הפתיחה אינה
; מסוכנת — המתאם מקבל רק הודעות חתומות HMAC במפתח שנגזר מקוד החברותא,
; וכל השאר נזרק בשקט.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Chavruta Companion (UDP-In)"" dir=in action=allow protocol=UDP localport={#LanPort} program=""{app}\{#MyAppExeName}"" profile=any"; Flags: runhidden waituntilterminated; Tasks: firewall; StatusMsg: "מוסיף חוק חומת אש…"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Chavruta Companion (UDP-Out)"" dir=out action=allow protocol=UDP program=""{app}\{#MyAppExeName}"" profile=any"; Flags: runhidden waituntilterminated; Tasks: firewall

Filename: "{app}\{#MyAppExeName}"; Parameters: "--hidden"; Description: "הפעלת המתאם עכשיו"; Flags: nowait postinstall skipifsilent runhidden
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
