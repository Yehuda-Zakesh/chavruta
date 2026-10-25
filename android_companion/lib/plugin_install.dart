/// מזהה התוסף בחנות התוספים הרשמית של אוצריא (otzaria.org). זהו המזהה
/// הפנימי של החנות ולא מזהה המניפסט — החנות מחזירה אותו בשדה `id` של
/// `/api/plugins/updates`, ו-404 על נתיב לפי מזהה המניפסט.
const String storePluginId = '6ac80bb4bd083fcc1856313c';

/// כתובת ההורדה מהחנות, **בלי גרסה**: אוצריא מוסיפה לה בעצמה את
/// `appVersion` שלה (`PluginStoreLinkParser.appendAppVersion`), והחנות מגישה
/// את גרסת התוסף הגבוהה ביותר שתואמת לאוצריא שמותקנת בטלפון.
const String pluginDownloadUrl =
    'https://otzaria.org/api/plugins/$storePluginId/download';

/// קישור ההתקנה של אוצריא (`docs/deep_links.md` בריפו של אוצריא). אוצריא
/// מורידה את הקובץ ומציגה את ההרשאות לאישור; `overwrite` מעדכן גרסה קיימת
/// בלי לשאול אם לדרוס, אך אינו מדלג על אישור ההרשאות.
String pluginInstallUri() => Uri(
  scheme: 'otzaria',
  host: 'plugin',
  path: '/install',
  queryParameters: {'url': pluginDownloadUrl, 'overwrite': 'true'},
).toString();
