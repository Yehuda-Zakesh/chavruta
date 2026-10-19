'use strict';

// טוען את קבצי התוסף לתוך הקשר `vm` משותף — בדיוק כפי שהדפדפן טוען אותם
// בתגי `<script>`: גלובליים משותפים, בלי מודולים. כך הבדיקות רצות על
// אותם קבצים שנארזים, ולא על עותק שהותאם ל-Node.

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.join(__dirname, '..', 'plugin');

/**
 * יוצר הקשר חדש וטוען לתוכו את [files] (יחסית לתיקיית התוסף).
 * [globals] נוספים להקשר לפני הטעינה — למשל `Otzaria` מדומה.
 */
function load(files, globals) {
  const context = vm.createContext(
    Object.assign(
      {
        console,
        setTimeout,
        clearTimeout,
        setInterval,
        clearInterval,
        TextEncoder,
        TextDecoder,
        // כמו בדפדפן: המסירה המסודרת של המנוע מבטלת בקשת נעילה ממתינה דרכו.
        AbortController,
        AbortSignal,
        crypto: globalThis.crypto,
        Promise,
        Date,
        Math,
        JSON,
      },
      globals || {}
    )
  );
  for (const file of files) {
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    // `const` בראש קובץ סקריפט אינו נעשה מאפיין של האובייקט הגלובלי,
    // ולכן הוא נחשף כאן במפורש — כפי שהוא זמין לסקריפטים הבאים בדף.
    const names = [...source.matchAll(/^const (\w+) = /gm)].map((m) => m[1]);
    const expose = names.map((n) => `globalThis.${n} = ${n};`).join('\n');
    vm.runInContext(source + '\n' + expose, context, { filename: file });
  }
  return context;
}

module.exports = { load, ROOT };
