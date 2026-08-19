<#
.SYNOPSIS
  אורז את תיקיית plugin לקובץ .otzplugin — בלי אוצריא מותקנת.

.DESCRIPTION
  קובץ .otzplugin הוא ZIP עם manifest.json בשורש, ולכן אפשר לייצר אותו בכל
  מקום. הסקריפט הזה קיים בשביל CI, שאין בו אוצריא.

  הוא מבצע ולידציה קלה בלבד — קיום המניפסט, השדות הנדרשים והקבצים שהם
  מצביעים עליהם. הוולידציה **המלאה** (הרשאות מול קריאות ה-API, תאימות
  DESIGN_GUIDE, גרסאות methods) קיימת רק באוצריא עצמה, ולכן בפיתוח מקומי
  עדיף לארוז עם `otzaria pack-plugin` — וזה מה ש-tool\build.ps1 עושה כשהיא
  מותקנת.

.EXAMPLE
  .\tool\pack-plugin.ps1
  .\tool\pack-plugin.ps1 -Output artifacts
#>
[CmdletBinding()]
param(
  [string]$Plugin = "",
  [string]$Output = "dist"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if ($Plugin -eq "") { $pluginDir = Join-Path $root "plugin" }
elseif ([System.IO.Path]::IsPathRooted($Plugin)) { $pluginDir = $Plugin }
else { $pluginDir = Join-Path $root $Plugin }

if ([System.IO.Path]::IsPathRooted($Output)) { $distDir = $Output }
else { $distDir = Join-Path $root $Output }

$manifestPath = Join-Path $pluginDir "manifest.json"
if (-not (Test-Path $manifestPath)) { throw "manifest.json לא נמצא ב-$pluginDir" }

$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($field in @('id', 'name', 'version', 'entrypoint', 'minAppVersion', 'sdkVersion')) {
  if (-not $manifest.$field) { throw "שדה חובה חסר ב-manifest.json: $field" }
}
if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') {
  throw "version ב-manifest.json אינו SemVer: $($manifest.version)"
}

# כל נתיב שהמניפסט מצביע עליו חייב להיות קיים — זו התקלה הנפוצה באריזה.
$referenced = @($manifest.entrypoint)
if ($manifest.icon) { $referenced += $manifest.icon }
if ($manifest.contributes -and $manifest.contributes.background -and $manifest.contributes.background.entrypoint) {
  $referenced += $manifest.contributes.background.entrypoint
}
foreach ($relative in $referenced) {
  $full = Join-Path $pluginDir $relative
  if (-not (Test-Path $full)) { throw "הקובץ $relative מוצהר במניפסט אך אינו קיים בתיקייה" }
}

New-Item -ItemType Directory -Force $distDir | Out-Null
$target = Join-Path $distDir "chavruta-$($manifest.version).otzplugin"
if (Test-Path $target) { Remove-Item $target -Force }

# תיקיות פיתוח אינן נכנסות לארכיון, בדיוק כמו באריזה של אוצריא.
$excluded = @('.git', 'node_modules', '.idea', '.vscode', '__pycache__', '.claude', '.dart_tool')
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("chavruta_pack_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $staging | Out-Null
try {
  Get-ChildItem $pluginDir -Force | Where-Object { $excluded -notcontains $_.Name } | ForEach-Object {
    Copy-Item $_.FullName -Destination $staging -Recurse -Force
  }

  # לא Compress-Archive: ב-Windows PowerShell הוא כותב שמות ערכים עם
  # לוכסן הפוך, בעוד שתקן ה-ZIP (ומפרק הארכיון של אוצריא) מצפה ל-'/'.
  # שני האסמבלים: ZipFile יושב ב-FileSystem, ו-ZipArchiveMode ב-Compression.
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::Open(
    $target, [System.IO.Compression.ZipArchiveMode]::Create
  )
  try {
    Get-ChildItem $staging -Recurse -File | ForEach-Object {
      $entry = $_.FullName.Substring($staging.Length + 1).Replace('\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive, $_.FullName, $entry,
        [System.IO.Compression.CompressionLevel]::Optimal
      ) | Out-Null
    }
  }
  finally {
    $archive.Dispose()
  }
}
finally {
  Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$size = (Get-Item $target).Length
Write-Host "נארז: $target ($size בייטים)" -ForegroundColor Green
Write-Host "ולידציה קלה בלבד — לוולידציה מלאה: otzaria pack-plugin" -ForegroundColor DarkGray
$target
