'use strict';

/**
 * הזנת ערכת הצבעים והגופנים של אוצריא לתוך משתני ה-CSS של התוסף.
 *
 * כל צבע בתוסף מגיע מכאן ולא מקודד ב-CSS, כדי שהתוסף ייראה זהה לאוצריא
 * בכל ערכת נושא שהמשתמש בחר ובמעבר בין מצב בהיר לכהה.
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

  const roles = {
    '--color-primary': cs.primary,
    '--color-on-primary': cs.onPrimary,
    '--color-secondary': cs.secondary,
    '--color-on-secondary': cs.onSecondary,
    '--color-secondary-container': cs.secondaryContainer,
    '--color-on-secondary-container': cs.onSecondaryContainer,
    '--color-surface': cs.surface,
    '--color-on-surface': cs.onSurface,
    '--color-on-surface-variant': cs.onSurfaceVariant,
    '--color-surface-container-high': cs.surfaceContainerHigh,
    '--color-surface-container-highest': cs.surfaceContainerHighest,
    '--color-error': cs.error,
    '--color-on-error': cs.onError,
    '--color-outline': cs.outline,
  };
  Object.keys(roles).forEach(function (name) {
    if (typeof roles[name] === 'string') root.style.setProperty(name, roles[name]);
  });

  // גוונים עדינים לרקעי הדגשה — נגזרים מהצבעים עצמם ולא מקודדים.
  const subtle = {
    '--color-primary-subtle': hexToRgba(cs.primary, 0.12),
    '--color-secondary-subtle': hexToRgba(cs.secondary, 0.12),
    '--color-error-subtle': hexToRgba(cs.error, 0.12),
  };
  Object.keys(subtle).forEach(function (name) {
    if (subtle[name]) root.style.setProperty(name, subtle[name]);
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
