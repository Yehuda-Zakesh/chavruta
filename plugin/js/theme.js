'use strict';

/**
 * הזנת ערכת הצבעים והגופנים של אוצריא לתוך משתני ה-CSS של התוסף.
 *
 * כל צבע בתוסף מגיע מכאן ולא מקודד ב-CSS, כדי שהתוסף ייראה זהה לאוצריא
 * בכל ערכת נושא שהמשתמש בחר ובמעבר בין מצב בהיר לכהה.
 *
 * מעבר לתפקידי הצבע שה-API מספק, נגזרים כאן שלושה סוגי טוקנים שאין להם
 * מקבילה ישירה ב-theme: גוונים שקופים להדגשות עדינות, צבעי צללית התלויים
 * במצב (כהה צריך צללית עמוקה יותר מבהיר), וקווי מסגרת עדינים.
 */
function hexToRgba(hex, alpha) {
  if (typeof hex !== 'string' || hex.charAt(0) !== '#' || hex.length < 7) {
    return null;
  }
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  if ([r, g, b].some(Number.isNaN)) return null;
  return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + alpha + ')';
}

function applyTheme(theme) {
  if (!theme || !theme.colorScheme) return;
  const cs = theme.colorScheme;
  const root = document.documentElement;
  const dark = theme.mode === 'dark';

  /** הצבע הראשון בשרשרת שה-theme אכן סיפק. */
  function pick() {
    for (let i = 0; i < arguments.length; i++) {
      if (typeof arguments[i] === 'string' && arguments[i] !== '') {
        return arguments[i];
      }
    }
    return null;
  }

  // --- תפקידי צבע של M3, ישר מה-API ---------------------------------------
  //
  // ערכות נושא ותיקות עשויות לא לספק את כל תפקידי ה-container; לכל אחד מהם
  // יש כאן נפילה אחורה לתפקיד קרוב שקיים בוודאות, כדי שלא ייווצר מצב שבו
  // רכיב מקבל את ברירת המחדל הבהירה שב-CSS דווקא בערכה כהה.
  const roles = {
    '--color-primary': cs.primary,
    '--color-on-primary': cs.onPrimary,
    '--color-primary-container': pick(cs.primaryContainer, cs.secondaryContainer),
    '--color-on-primary-container': pick(
      cs.onPrimaryContainer,
      cs.onSecondaryContainer,
      cs.onSurface
    ),
    '--color-secondary': cs.secondary,
    '--color-on-secondary': cs.onSecondary,
    '--color-secondary-container': cs.secondaryContainer,
    '--color-on-secondary-container': pick(cs.onSecondaryContainer, cs.onSurface),
    '--color-tertiary': pick(cs.tertiary, cs.secondary),
    '--color-on-tertiary': pick(cs.onTertiary, cs.onSecondary),
    '--color-surface': cs.surface,
    '--color-on-surface': cs.onSurface,
    '--color-on-surface-variant': cs.onSurfaceVariant,
    '--color-surface-container-lowest': pick(cs.surfaceContainerLowest, cs.surface),
    '--color-surface-container-low': pick(
      cs.surfaceContainerLow,
      cs.surfaceContainer,
      cs.surface
    ),
    '--color-surface-container': pick(
      cs.surfaceContainer,
      cs.surfaceContainerLow,
      cs.surfaceContainerHigh
    ),
    '--color-surface-container-high': cs.surfaceContainerHigh,
    '--color-surface-container-highest': cs.surfaceContainerHighest,
    '--color-error': cs.error,
    '--color-on-error': cs.onError,
    '--color-error-container': pick(cs.errorContainer, cs.surfaceContainerHigh),
    '--color-on-error-container': pick(cs.onErrorContainer, cs.error),
    '--color-outline': cs.outline,
    '--color-inverse-surface': pick(cs.inverseSurface, cs.onSurface),
    '--color-on-inverse-surface': pick(cs.onInverseSurface, cs.surface),
  };
  Object.keys(roles).forEach(function (name) {
    if (typeof roles[name] === 'string') root.style.setProperty(name, roles[name]);
  });

  // --- טוקנים נגזרים ------------------------------------------------------
  //
  // גוונים עדינים לרקעי הדגשה, קווי מסגרת ושכבות צללית — כולם נגזרים מצבעי
  // ה-theme עצמם. במצב כהה השקיפויות גבוהות יותר: אותם 12% שנראים עדינים
  // מעל רקע בהיר נעלמים כמעט לגמרי מעל רקע כהה.
  const shadow = pick(cs.shadow, '#000000');
  const derived = {
    '--color-primary-faint': hexToRgba(cs.primary, dark ? 0.1 : 0.06),
    '--color-primary-subtle': hexToRgba(cs.primary, dark ? 0.18 : 0.12),
    '--color-primary-hover': hexToRgba(cs.primary, dark ? 0.26 : 0.16),
    '--color-secondary-faint': hexToRgba(cs.secondary, dark ? 0.12 : 0.07),
    '--color-secondary-subtle': hexToRgba(cs.secondary, dark ? 0.2 : 0.12),
    '--color-tertiary-subtle': hexToRgba(pick(cs.tertiary, cs.secondary), dark ? 0.2 : 0.12),
    '--color-error-subtle': hexToRgba(cs.error, dark ? 0.2 : 0.12),
    '--color-error-faint': hexToRgba(cs.error, dark ? 0.12 : 0.07),

    // מפריד עדין: outlineVariant אם הערכה מספקת אותו, ואחרת outline מרוכך.
    '--color-outline-variant': pick(
      cs.outlineVariant,
      hexToRgba(cs.outline, dark ? 0.45 : 0.35)
    ),
    '--color-outline-faint': hexToRgba(cs.outline, dark ? 0.3 : 0.2),

    // שלוש מדרגות של עומק צללית. הן משמשות ב-box-shadow בלבד, ולכן נשמרות כצבע ולא
    // כצללית שלמה — כך אותה מדרגת עומק נשמרת גם כשה-theme מתחלף.
    '--shadow-tint-soft': hexToRgba(shadow, dark ? 0.32 : 0.05),
    '--shadow-tint-weak': hexToRgba(shadow, dark ? 0.42 : 0.08),
    '--shadow-tint-strong': hexToRgba(shadow, dark ? 0.55 : 0.14),
  };
  Object.keys(derived).forEach(function (name) {
    if (derived[name]) root.style.setProperty(name, derived[name]);
  });

  document.body.classList.toggle('dark-mode', theme.mode === 'dark');

  if (theme.typography) {
    const t = theme.typography;
    if (t.fontFamily) {
      root.style.setProperty('--font-main', "'" + t.fontFamily + "', 'David', serif");
    }
    // גודל הגופן הוא זה שהמשתמש בחר באוצריא (16–36), כמו בכל מסך אחר
    // שלה. כל המידות בתוסף יחסיות אליו, ולכן הפריסה נשארת שלמה בכל גודל —
    // חוץ מפס הכותרת, שנשאר בגובה הסרגל של אוצריא.
    if (typeof t.fontSize === 'number' && t.fontSize > 0) {
      root.style.setProperty('--font-size-base', t.fontSize + 'px');
    }
    if (typeof t.lineHeight === 'number') {
      root.style.setProperty('--line-height', String(t.lineHeight));
    }
  }
}
