import 'package:chavruta_android/plugin_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ההורדה היא מהחנות הרשמית, בלי גרסה קבועה', () {
    final url = Uri.parse(pluginDownloadUrl);
    // אוצריא מוסיפה appVersion רק לכתובת https של otzaria.org שמסתיימת
    // ב-download ואין בה `@גרסה` — אחרת היא מתייחסת אליה כהורדה חיצונית.
    expect(url.scheme, 'https');
    expect(url.host, 'otzaria.org');
    expect(url.pathSegments.last, 'download');
    expect(url.path.contains('@'), isFalse);
    expect(url.hasQuery, isFalse);
  });

  test('קישור ההתקנה הוא plugin/install עם הכתובת מקודדת', () {
    final uri = Uri.parse(pluginInstallUri());
    expect(uri.scheme, 'otzaria');
    expect(uri.host, 'plugin');
    expect(uri.path, '/install');
    expect(uri.queryParameters['url'], pluginDownloadUrl);
    expect(uri.queryParameters['overwrite'], 'true');
  });
}
