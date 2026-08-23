<#
.SYNOPSIS
  מייצר את קובצי האייקון של חברותא מתוך assets\icon-256.png.

.DESCRIPTION
  האייקון שהיה בריפו עד כה היה תמונה אחת של 48x48 ב-4 ביט לפיקסל — 16
  צבעים ובלי ערוץ אלפא. התוצאה הייתה סמל דהוי, כמעט חסר צבע, ומרוח בכל
  גודל שאינו 48: המערכת נאלצה למתוח את התמונה היחידה שהייתה לה.

  כאן נכתבים במקומו שני קבצים תקניים, ובכוונה שניים:

    assets\chavruta.ico        16 עד 256. הקובץ שנשלח עם ההתקנה, ומותקן
                               לצד התוכנה. ממנו האייקון של המתקין, של
                               קיצור הדרך ושל רשומת ההסרה — כלומר כל
                               המקומות שבהם נראים הגדלים הגדולים.

    assets\chavruta-small.ico  16 עד 64, וזה שמוטבע ב-ChavrutaLauncher.exe
                               (ראו launcher\chavruta_launcher.rc). האייקון
                               *המוטבע* בקובץ הפעלה נראה רק במנהל המשימות,
                               בתיבת חומת האש ובעיון בתיקיית ההתקנה — כולם
                               48 ומטה. הכללת 128 ו-256 שם הייתה מוסיפה
                               כ-167KB לקובץ שכל הקוד שבו הוא 3.5KB, בלי
                               שאיש יראה אותם: קיצור הדרך אינו קורא את
                               המשאב שבתוך ה-exe אלא את קובץ ה-ico שלידו.

  כל תמונה נכתבת בקידוד הקטן מבין השניים — DIB לא דחוס, או PNG. לציור
  הזה PNG מנצח בכל הגדלים וחוסך כמחצית (256x256: ‏130KB מול 264KB), ולכן
  הוא שנבחר בפועל. PNG בתוך ICO נתמך ב-Windows מ-Vista והלאה.

  ההקטנה היא מיצוע שטח (box filter) על ערכים מוכפלי-אלפא. שני הפרטים
  האלה חשובים:
    - מיצוע שטח ולא bicubic: ב-bicubic יש overshoot סביב הקצוות החדים של
      מסגרת הזהב, שנראה כהילה בגדלים הקטנים.
    - הכפלה באלפא לפני המיצוע: בלעדיה, פיקסל שקוף (שצבעו שרירותי) מזהם
      את שכניו הגלויים, ומסביב לספר מופיע שפה כהה.

  הסקריפט אינו חלק מהבנייה: האייקונים הם נכסים בריפו, ומריצים את זה רק
  כשמחליפים את תמונת המקור.

.EXAMPLE
  .\tool\make-icon.ps1
#>
[CmdletBinding()]
param(
  [string]$Source = "assets\icon-256.png",
  [string]$Output = "assets\chavruta.ico",
  [string]$SmallOutput = "assets\chavruta-small.ico",
  # 16 עד 256: הגדלים ש-Windows מבקש בפועל בין רשימת קבצים צפופה לבין
  # שולחן עבודה במסך 4K. 20/40 אינם כאן בכוונה — הם נגזרים מ-16/48 בקנה
  # מידה של 125%, והמערכת מקטינה אליהם היטב בעצמה.
  [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
  [int[]]$SmallSizes = @(16, 24, 32, 48, 64)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Resolve-Under {
  param([string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $root $Path)
}

$sourcePath = Resolve-Under $Source
if (-not (Test-Path $sourcePath)) { throw "תמונת המקור לא נמצאה: $sourcePath" }

Add-Type -AssemblyName System.Drawing

# --- קריאת המקור ל-BGRA שטוח ומוכפל-אלפא ---------------------------------

$bitmap = New-Object System.Drawing.Bitmap($sourcePath)
try {
  $srcW = $bitmap.Width
  $srcH = $bitmap.Height
  $largest = (($Sizes + $SmallSizes) | Measure-Object -Maximum).Maximum
  if ($srcW -lt $largest) {
    Write-Warning "המקור ($srcW פיקסלים) קטן מהגודל הגדול ביותר שמבוקש ($largest) — הגדלה תיראה מטושטשת."
  }

  # LockBits ל-Format32bppArgb: גם JPG בלי אלפא מתורגם כך, ואז האלפא 255
  # בכל הפיקסלים — הנוסחאות שלמטה נכונות בשני המקרים.
  $rect = New-Object System.Drawing.Rectangle(0, 0, $srcW, $srcH)
  $locked = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $raw = New-Object byte[] ($locked.Stride * $srcH)
    [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $raw, 0, $raw.Length)
    $stride = $locked.Stride
  }
  finally {
    $bitmap.UnlockBits($locked)
  }
}
finally {
  $bitmap.Dispose()
}

# ארבעה מערכי double מקבילים, ולא מערך של אובייקטים: מיצוע במערכים
# פרימיטיביים הוא בסדר גודל מהיר יותר ב-PowerShell.
$count = $srcW * $srcH
$srcB = New-Object double[] $count
$srcG = New-Object double[] $count
$srcR = New-Object double[] $count
$srcA = New-Object double[] $count

for ($y = 0; $y -lt $srcH; $y++) {
  $row = $y * $stride
  $out = $y * $srcW
  for ($x = 0; $x -lt $srcW; $x++) {
    $i = $row + $x * 4
    $a = [double]$raw[$i + 3]
    $scale = $a / 255.0
    $j = $out + $x
    # מוכפל-אלפא כבר כאן, כדי שכל המיצועים שלמטה יהיו במרחב הנכון.
    $srcB[$j] = $raw[$i] * $scale
    $srcG[$j] = $raw[$i + 1] * $scale
    $srcR[$j] = $raw[$i + 2] * $scale
    $srcA[$j] = $a
  }
}

# --- הקטנה במיצוע שטח ----------------------------------------------------

# מחזיר מערך בתים בסדר BGRA, שורות מלמעלה למטה, אלפא לא-מוכפל (כפי
# שדורשים גם ICO וגם PNG).
function Get-ScaledBgra {
  param([int]$Size)

  $bytes = New-Object byte[] ($Size * $Size * 4)
  $xRatio = $srcW / [double]$Size
  $yRatio = $srcH / [double]$Size

  for ($ty = 0; $ty -lt $Size; $ty++) {
    # תחום המקור שממנו נגזר פיקסל היעד. Ceiling ולא Floor בקצה העליון,
    # כדי שביחס לא-שלם (256/48) לא יישמט פיקסל בין שני יעדים סמוכים.
    $y0 = [int][Math]::Floor($ty * $yRatio)
    $y1 = [int][Math]::Ceiling(($ty + 1) * $yRatio)
    if ($y1 -gt $srcH) { $y1 = $srcH }
    if ($y1 -le $y0) { $y1 = $y0 + 1 }

    for ($tx = 0; $tx -lt $Size; $tx++) {
      $x0 = [int][Math]::Floor($tx * $xRatio)
      $x1 = [int][Math]::Ceiling(($tx + 1) * $xRatio)
      if ($x1 -gt $srcW) { $x1 = $srcW }
      if ($x1 -le $x0) { $x1 = $x0 + 1 }

      $sumB = 0.0; $sumG = 0.0; $sumR = 0.0; $sumA = 0.0; $n = 0
      for ($y = $y0; $y -lt $y1; $y++) {
        $row = $y * $srcW
        for ($x = $x0; $x -lt $x1; $x++) {
          $j = $row + $x
          $sumB += $srcB[$j]; $sumG += $srcG[$j]; $sumR += $srcR[$j]; $sumA += $srcA[$j]
          $n++
        }
      }

      $avgA = $sumA / $n
      $i = ($ty * $Size + $tx) * 4
      if ($avgA -le 0.5) {
        # שקוף לגמרי: משאירים אפס בכל הערוצים, בלי לחלק באלפא אפס.
        continue
      }
      # ביטול ההכפלה, כי גם ICO וגם PNG שומרים אלפא לא-מוכפל.
      $unscale = 255.0 / $avgA
      $bytes[$i]     = [byte][Math]::Min(255, [Math]::Round(($sumB / $n) * $unscale))
      $bytes[$i + 1] = [byte][Math]::Min(255, [Math]::Round(($sumG / $n) * $unscale))
      $bytes[$i + 2] = [byte][Math]::Min(255, [Math]::Round(($sumR / $n) * $unscale))
      $bytes[$i + 3] = [byte][Math]::Round($avgA)
    }
  }
  return $bytes
}

# --- שני הקידודים של תמונה בודדת -----------------------------------------

# DIB: BITMAPINFOHEADER, אחריו הפיקסלים מלמטה למעלה, ואחריהם מסכת AND.
# במקרה של 32 ביט המסכה מיותרת (השקיפות היא באלפא), אבל היא חלק מהמבנה:
# biHeight מוכפל בשתיים בגללה, ובלעדיה קוראים שמסתמכים על המבנה הרשמי
# מקבלים תמונה חתוכה.
function Get-DibImage {
  param([int]$Size, [byte[]]$Bgra)

  $maskRow = [int][Math]::Floor(($Size + 31) / 32) * 4
  $stream = New-Object System.IO.MemoryStream
  $writer = New-Object System.IO.BinaryWriter($stream)
  try {
    $writer.Write([uint32]40)          # biSize
    $writer.Write([int32]$Size)        # biWidth
    $writer.Write([int32]($Size * 2))  # biHeight — התמונה והמסכה יחד
    $writer.Write([uint16]1)           # biPlanes
    $writer.Write([uint16]32)          # biBitCount
    $writer.Write([uint32]0)           # biCompression = BI_RGB
    $writer.Write([uint32]($Size * $Size * 4))
    $writer.Write([int32]0)            # biXPelsPerMeter
    $writer.Write([int32]0)            # biYPelsPerMeter
    $writer.Write([uint32]0)           # biClrUsed
    $writer.Write([uint32]0)           # biClrImportant

    for ($y = $Size - 1; $y -ge 0; $y--) {
      $writer.Write($Bgra, $y * $Size * 4, $Size * 4)
    }
    $writer.Write((New-Object byte[] ($maskRow * $Size)))

    $writer.Flush()
    return $stream.ToArray()
  }
  finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

# PNG שלם — כותרת וכל — כתחליף ל-DIB באותו ערך בטבלת האייקון. מוכר
# ב-Windows מ-Vista, וכאן הוא חוסך כמחצית מהמשקל.
function Get-PngImage {
  param([int]$Size, [byte[]]$Bgra)

  $bmp = New-Object System.Drawing.Bitmap($Size, $Size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stream = New-Object System.IO.MemoryStream
  try {
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $locked = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      # שורה-שורה ולא בהעתקה אחת: ה-stride של GDI+ אינו מובטח שווה
      # לרוחב כפול ארבע.
      for ($y = 0; $y -lt $Size; $y++) {
        $target = [IntPtr]::Add($locked.Scan0, $y * $locked.Stride)
        [System.Runtime.InteropServices.Marshal]::Copy($Bgra, $y * $Size * 4, $target, $Size * 4)
      }
    }
    finally {
      $bmp.UnlockBits($locked)
    }
    $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    return $stream.ToArray()
  }
  finally {
    $stream.Dispose()
    $bmp.Dispose()
  }
}

# --- הרכבת קובץ ICO ------------------------------------------------------

# הטבלה בראש הקובץ נראית אותו דבר בשני הקידודים: הרוחב, הגובה ועומק
# הצבע נלקחים ממנה ולא מגוף התמונה, ולכן קורא שאינו מזהה PNG עדיין
# מדווח על הערך נכון (ורק אינו יודע לפענח אותו).
function Write-Ico {
  param([string]$Path, [int[]]$Order, [hashtable]$Images)

  New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
  $file = [System.IO.File]::Create($Path)
  $writer = New-Object System.IO.BinaryWriter($file)
  try {
    $writer.Write([uint16]0)               # reserved
    $writer.Write([uint16]1)               # type = icon
    $writer.Write([uint16]$Order.Count)

    # ההיסט של התמונה הראשונה: הכותרת ואחריה טבלת הערכים.
    $offset = 6 + 16 * $Order.Count
    foreach ($size in $Order) {
      # 256 נרשם כאפס — הרוחב והגובה בטבלה הם בית אחד כל אחד.
      $dimension = if ($size -ge 256) { 0 } else { $size }
      $writer.Write([byte]$dimension)
      $writer.Write([byte]$dimension)
      $writer.Write([byte]0)                 # מספר צבעי הלוח — אין לוח
      $writer.Write([byte]0)                 # reserved
      $writer.Write([uint16]1)               # planes
      $writer.Write([uint16]32)              # bpp
      $writer.Write([uint32]$Images[$size].Length)
      $writer.Write([uint32]$offset)
      $offset += $Images[$size].Length
    }
    foreach ($size in $Order) { $writer.Write($Images[$size]) }
  }
  finally {
    $writer.Dispose()
    $file.Dispose()
  }
}

# --- ייצור ---------------------------------------------------------------

$targets = @(
  @{ Path = (Resolve-Under $Output);      Sizes = @($Sizes | Sort-Object -Unique) },
  @{ Path = (Resolve-Under $SmallOutput); Sizes = @($SmallSizes | Sort-Object -Unique) }
)

# הגדלים המשותפים לשני הקבצים מוקטנים ומקודדים פעם אחת.
$images = @{}
foreach ($size in (($Sizes + $SmallSizes) | Sort-Object -Unique)) {
  $bgra = [byte[]](Get-ScaledBgra -Size $size)
  # ההמרה ל-byte[] מפורשת: PowerShell מפרק מערך שחוזר מפונקציה ל-Object[],
  # ואז BinaryWriter.Write בוחר את העומס של bool — בית אחד לכל תמונה.
  $dib = [byte[]](Get-DibImage -Size $size -Bgra $bgra)
  $png = [byte[]](Get-PngImage -Size $size -Bgra $bgra)
  if ($png.Length -lt $dib.Length) { $images[$size] = $png; $chosen = "PNG" }
  else { $images[$size] = $dib; $chosen = "DIB" }
  Write-Host ("  {0,3}x{0,-4} {1}  {2,7:N0} בתים (DIB: {3:N0})" -f `
    $size, $chosen, $images[$size].Length, $dib.Length) -ForegroundColor Gray
}

Write-Host ""
foreach ($target in $targets) {
  Write-Ico -Path $target.Path -Order $target.Sizes -Images $images
  Write-Host ("{0} ({1:N0} בתים; {2})" -f $target.Path, (Get-Item $target.Path).Length,
    ($target.Sizes -join ", ")) -ForegroundColor Green
}
