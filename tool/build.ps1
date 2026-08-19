<#
.SYNOPSIS
  בונה את חבילת ההפצה של חברותא: המתאם, התוסף והמתקין.

.DESCRIPTION
  שלושה שלבים, כל אחד מהם נעצר בשגיאה הראשונה:
    1. המתאם  — pub get, analyze, test, ואז dart compile exe.
    2. התוסף  — אריזה ל-.otzplugin דרך אוצריא (שכוללת ולידציית מניפסט ועיצוב).
    3. המתקין — קימפול chavruta.iss ב-Inno Setup, אם הוא מותקן.

  הפלט כולו נכתב לתיקיית dist.

.PARAMETER Otzaria
  נתיב ל-otzaria.exe, לאריזת התוסף. אם לא צוין, מחפשים ב-PATH, בתיקיות
  ההתקנה המקובלות, ולבסוף ב-build של ריפו otzaria שליד הריפו הזה.

.EXAMPLE
  .\tool\build.ps1
  .\tool\build.ps1 -SkipTests -SkipInstaller
#>
[CmdletBinding()]
param(
  [string]$Output = "dist",
  [string]$Otzaria = "",
  [switch]$SkipTests,
  [switch]$SkipPlugin,
  [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert-LastExitCode {
  param([string]$What)
  if ($LASTEXITCODE -ne 0) { throw "$What נכשל (קוד יציאה $LASTEXITCODE)" }
}

function Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

# הפלט מוחלט, כי אנחנו מחליפים תיקיית עבודה בדרך.
if ([System.IO.Path]::IsPathRooted($Output)) { $distDir = $Output }
else { $distDir = Join-Path $root $Output }
New-Item -ItemType Directory -Force $distDir | Out-Null

$manifest = Get-Content (Join-Path $root "plugin\manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$version = $manifest.version

Write-Host "חברותא $version" -ForegroundColor Green
Write-Host "פלט: $distDir"

# --- 1. המתאם -------------------------------------------------------------

Step "בונה את המתאם"
Push-Location (Join-Path $root "companion")
try {
  dart pub get
  Assert-LastExitCode "dart pub get"

  dart analyze
  Assert-LastExitCode "dart analyze"

  if (-not $SkipTests) {
    dart test
    Assert-LastExitCode "dart test"
  }

  $exe = Join-Path $distDir "ChavrutaCompanion.exe"
  dart compile exe bin\chavruta_companion.dart -o $exe
  Assert-LastExitCode "dart compile exe"

  # dart compile כותב את הקובץ באותיות קטנות; מחזירים את השם התקני, כדי
  # שמה שמותקן ב-Program Files ייראה כמו שם ולא כמו פלט של כלי בנייה.
  $built = Get-ChildItem $distDir -Filter "chavrutacompanion.exe" | Select-Object -First 1
  if ($null -ne $built -and $built.Name -cne "ChavrutaCompanion.exe") {
    Rename-Item $built.FullName "ChavrutaCompanion.exe" -Force
  }
  Write-Host "  $exe" -ForegroundColor Gray
}
finally {
  Pop-Location
}

# --- 2. התוסף -------------------------------------------------------------

function Find-Otzaria {
  if ($Otzaria -ne "") {
    if (-not (Test-Path $Otzaria)) { throw "otzaria.exe לא נמצא בנתיב $Otzaria" }
    return $Otzaria
  }

  $fromPath = Get-Command otzaria -ErrorAction SilentlyContinue
  if ($null -ne $fromPath) { return $fromPath.Source }

  $candidates = @(
    "$env:ProgramFiles\otzaria\otzaria.exe",
    "$env:LOCALAPPDATA\Programs\otzaria\otzaria.exe",
    (Join-Path (Split-Path -Parent $root) "otzaria\build\windows\x64\runner\Release\otzaria.exe"),
    (Join-Path (Split-Path -Parent $root) "otzaria\build\windows\x64\runner\Debug\otzaria.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

$pluginFile = "chavruta-$version.otzplugin"
if ($SkipPlugin) {
  Write-Host ""
  Write-Host "==> מדלג על אריזת התוסף" -ForegroundColor DarkGray
}
else {
  Step "אורז את התוסף"
  $target = Join-Path $distDir $pluginFile
  $otz = Find-Otzaria

  if ($null -eq $otz) {
    # בלי אוצריא אין ולידציה מלאה, אבל אריזה כן — כך CI עובד בלי התקנה.
    Write-Warning "אוצריא לא נמצאה — אורז בלי ולידציה מלאה (הרשאות, תאימות עיצוב)."
    & (Join-Path $PSScriptRoot "pack-plugin.ps1") -Output $distDir | Out-Null
  }
  else {
    Write-Host "  אוצריא: $otz" -ForegroundColor Gray

    # אוצריא היא אפליקציית חלונות, ולכן קריאה רגילה אליה חוזרת מיד ו-
    # $LASTEXITCODE אינו נקבע. ממתינים לתהליך, ובודקים לפי הקובץ.
    if (Test-Path $target) { Remove-Item $target -Force }
    $packer = Start-Process -FilePath $otz -Wait -PassThru -NoNewWindow -ArgumentList @(
      "pack-plugin", (Join-Path $root "plugin"), "--force", "-o", $target
    )
    if (-not (Test-Path $target)) {
      throw "אריזת התוסף נכשלה (קוד יציאה $($packer.ExitCode)). הריצו את הפקודה ידנית כדי לראות את דוח הוולידציה."
    }
  }
  Write-Host "  $target" -ForegroundColor Gray
}

# --- 3. המתקין ------------------------------------------------------------

function Find-Iscc {
  $fromPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($null -ne $fromPath) { return $fromPath.Source }
  $candidates = @(
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

if ($SkipInstaller) {
  Write-Host ""
  Write-Host "==> מדלג על בניית המתקין" -ForegroundColor DarkGray
}
else {
  Step "בונה את המתקין"
  $iscc = Find-Iscc
  if ($null -eq $iscc) {
    Write-Warning "Inno Setup (ISCC.exe) לא נמצא — המתקין לא נבנה. התקינו אותו או הריצו עם -SkipInstaller."
  }
  else {
    $packed = ""
    if (Test-Path (Join-Path $distDir $pluginFile)) { $packed = $pluginFile }

    & $iscc "/DMyAppVersion=$version" "/DDistDir=$distDir" "/DPluginFile=$packed" (Join-Path $root "installer\chavruta.iss")
    Assert-LastExitCode "ISCC"
  }
}

Write-Host ""
Write-Host "הבנייה הושלמה." -ForegroundColor Green
Get-ChildItem $distDir | Select-Object Name, Length | Format-Table
