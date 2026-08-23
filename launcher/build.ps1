<#
.SYNOPSIS
  בונה את משגר המתאם — ChavrutaLauncher.exe.

.DESCRIPTION
  המשגר הוא תוכנית זעירה בתת-מערכת חלונות, שכל תפקידה להפעיל את המתאם
  בלי שייווצר חלון קונסולה כלל. הרקע המלא — למה ההסתרה מתוך המתאם עצמו
  אינה עובדת ב-Windows 11 — מתועד בראש launcher/chavruta_launcher.c.

  הבנייה היא ב-MSVC בלי ספריית CRT, ולכן הקוד הוא כמה קילובייטים בלי
  שום תלות מלבד kernel32 — ומעליהם האייקון, שמוטבע כמשאב מתוך
  launcher/chavruta_launcher.rc ותופס את רוב גודלו של הקובץ (27KB).

  בלי MSVC מותקן הסקריפט מדווח ויוצא בלי לבנות: tool/build.ps1 ממשיך
  בלעדיו, והמתקין נופל חזרה לרישום המתאם עצמו לעלייה — כלומר להתנהגות
  שהייתה לפני המשגר, כולל החלון.

.PARAMETER Output
  תיקיית הפלט. ברירת מחדל: dist שבשורש הריפו.

.PARAMETER Required
  כשל אם MSVC אינו מותקן, במקום אזהרה. כך רץ ב-CI, שבו שחרור בלי משגר
  הוא באג ולא ויתור.

.EXAMPLE
  .\launcher\build.ps1
  .\launcher\build.ps1 -Output dist -Required
#>
[CmdletBinding()]
param(
  [string]$Output = "dist",
  [switch]$Required
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if ([System.IO.Path]::IsPathRooted($Output)) { $distDir = $Output }
else { $distDir = Join-Path $root $Output }
New-Item -ItemType Directory -Force $distDir | Out-Null

# vcvars64.bat ולא cl.exe ישירות: בלי משתני הסביבה שהוא קובע (INCLUDE,
# LIB, PATH אל ה-Windows SDK) הקימפול נכשל על כל #include.
function Find-VcVars {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $installPath = & $vswhere -latest -products * `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
      -property installationPath
    if ($installPath) {
      $candidate = Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat"
      if (Test-Path $candidate) { return $candidate }
    }
  }

  foreach ($edition in @("BuildTools", "Community", "Professional", "Enterprise")) {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
      $candidate = Join-Path $base "Microsoft Visual Studio\2022\$edition\VC\Auxiliary\Build\vcvars64.bat"
      if (Test-Path $candidate) { return $candidate }
    }
  }
  return $null
}

$vcvars = Find-VcVars
if ($null -eq $vcvars) {
  $message = "MSVC לא נמצא (vcvars64.bat) — המשגר לא נבנה. התקינו Visual Studio Build Tools עם עומס העבודה של C++."
  if ($Required) { throw $message }
  Write-Warning $message
  return
}

$source = Join-Path $PSScriptRoot "chavruta_launcher.c"
$script = Join-Path $PSScriptRoot "chavruta_launcher.rc"
$exe = Join-Path $distDir "ChavrutaLauncher.exe"
$objDir = Join-Path ([System.IO.Path]::GetTempPath()) "chavruta-launcher"
New-Item -ItemType Directory -Force $objDir | Out-Null
$obj = Join-Path $objDir "chavruta_launcher.obj"
$res = Join-Path $objDir "chavruta_launcher.res"

# האייקון הוא נכס בריפו ולא תוצר בנייה, אבל בדיקה כאן עדיפה על שגיאת
# rc.exe סתומה.
$icon = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\chavruta-small.ico"
if (-not (Test-Path $icon)) { throw "האייקון לא נמצא ($icon). ייצרו אותו ב-tool\make-icon.ps1." }

# /GS- ו-/nodefaultlib הולכים יחד: בלי CRT אין __security_check_cookie
# שבודק את עוגיית המחסנית, ואין memset. /entry:start כי אין
# wWinMainCRTStartup שיקרא לנקודת כניסה רגילה.
$compile = "cl /nologo /W4 /O1 /GS- /c `"$source`" /Fo`"$obj`""
# ה-rc אינו מקומפל מהתיקייה הזו סתם: rc.exe מחפש את הקובץ שמופיע במשפט
# ICON יחסית לתיקיית העבודה, ולכן הנתיב ..\assets שבתוכו תקף רק כאן.
$resource = "rc /nologo /fo `"$res`" `"$script`""
$link = "link /nologo /subsystem:windows /entry:start /nodefaultlib /opt:ref /out:`"$exe`" `"$obj`" `"$res`" kernel32.lib"

if (Test-Path $exe) { Remove-Item $exe -Force }
& cmd /c "call `"$vcvars`" >nul && cd /d `"$PSScriptRoot`" && $resource && $compile && $link"
if ($LASTEXITCODE -ne 0) { throw "בניית המשגר נכשלה (קוד יציאה $LASTEXITCODE)" }
if (-not (Test-Path $exe)) { throw "בניית המשגר לא הפיקה את $exe" }

Remove-Item $objDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("  {0} ({1:N0} בתים)" -f $exe, (Get-Item $exe).Length) -ForegroundColor Gray
