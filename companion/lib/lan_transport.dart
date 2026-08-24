import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// כתובת ה-broadcast של רשת link-local (169.254.x.x).
const String linkLocalBroadcast = '169.254.255.255';

/// כל כמה זמן נבדק שהסוקט חי, ואם לא — מנסים לבנות אותו מחדש.
///
/// ראו [LanTransport.reportSocketFailure] להסבר למה סוקט UDP ב-Windows
/// מת מעצמו, ולמה בלי הבדיקה הזאת הסנכרון פשוט מפסיק לעבוד בלי סימן.
const Duration socketWatchdogInterval = Duration(seconds: 5);

/// כמה זמן רשימת יעדי השידור נשמרת בלי למנות מחדש את כרטיסי הרשת.
///
/// מניית הכרטיסים היא קריאת מערכת, והיא הייתה רצה בכל שידור — כלומר גם
/// בכל מעבר דף. חלון קצר כזה חוסך את רובן ועדיין מגלה שינוי רשת מהר;
/// וממילא נפילת סוקט מאפסת את המטמון מיד.
const Duration targetsCacheTtl = Duration(seconds: 3);

/// כמה שידורים רצופים שבהם *אף* בייט לא יצא נחשבים לסוקט מת.
///
/// שידור שחוזר 0 הוא בדרך כלל חוצץ מלא לרגע, ולכן לא מגיבים לאחד בודד;
/// שניים ברצף לכל היעדים כבר אומרים שהסוקט אינו שולח יותר כלום.
const int deadSendThreshold = 2;

/// שידור וקליטה של הודעות חברותא ברשת המקומית, על UDP broadcast.
///
/// אין שרת ואין הגדרת כתובות: כל מתאם משדר לכל הרשת, וכל מתאם מסנן
/// לפי גיבוב קוד החברותא וחתימת ה-HMAC. לכן שני מחשבים על אותו ראוטר
/// מוצאים זה את זה בלי שום קונפיגורציה.
class LanTransport {
  LanTransport({required this.roomCodeProvider, this.onLog});

  /// מספק את קוד החברותא **הנוכחי**. פונקציה ולא ערך, כי המשתמש יכול
  /// לשנות קוד בזמן ריצה והתעבורה חייבת לעבור לחדר החדש מיד.
  final String? Function() roomCodeProvider;

  final void Function(String message)? onLog;

  /// נקרא אחרי שהסוקט קם מחדש בעקבות נפילה. ה-hub משדר בעקבותיו נוכחות
  /// מיידית, כדי שהחברותא לא תמתין עוד מחזור שלם כדי לראות אותנו שוב.
  void Function()? onRebound;

  RawDatagramSocket? _socket;
  Timer? _watchdog;

  /// מונע שתי בנייות מקבילות של הסוקט (שומר הסף ושידור שנתקל בסוקט מת).
  bool _binding = false;

  /// אחרי [dispose] אין קמים מחדש — גם לא בעקבות שגיאה שהגיעה באיחור.
  bool _disposed = false;

  /// האם הסוקט נפל מאז שעלה, כלומר הקימה הבאה היא התאוששות ולא עלייה.
  bool _recovering = false;

  String? _lastError;

  /// פער השעונים (בדקות) שבגללו נדחתה הודעה מהחברותא, או `null` אם אין
  /// בעיה כזאת. מתאפס ברגע שהודעה כן מתקבלת.
  int? _clockSkewMinutes;

  int _deadSends = 0;
  List<String> _lastTargets = const [];

  /// יעדי השידור שנמנו לאחרונה, ובן כמה הם. ראו [targetsCacheTtl].
  List<String>? _cachedTargets;
  final Stopwatch _targetsAge = Stopwatch();

  final _inbound = StreamController<SyncMessage>.broadcast();

  /// הודעות שעברו אימות חתימה, טריות, ואינן שלנו.
  Stream<SyncMessage> get inbound => _inbound.stream;

  /// האם יש כרגע סוקט חי. **לא** "האם הצלחנו פעם" — התוסף מציג לפי זה
  /// שהסנכרון מושבת, ולכן חובה שיהיה נכון גם אחרי נפילה.
  bool get isBound => _socket != null;

  /// תיאור התקלה האחרונה ברשת, לתצוגה בתוסף וביומן. `null` = הכול תקין.
  String? get lastError => _lastError;

  /// פער השעונים מול החברותא, בדקות, כשהוא זה שמפיל את ההודעות.
  int? get clockSkewMinutes => _clockSkewMinutes;

  Future<bool> start() async {
    _watchdog ??= Timer.periodic(
      socketWatchdogInterval,
      (_) => unawaited(_bind()),
    );
    return _bind();
  }

  /// בונה את הסוקט אם אין. מחזיר האם יש סוקט חי בסוף הפעולה.
  Future<bool> _bind() async {
    if (_disposed) return false;
    if (_socket != null) return true;
    if (_binding) return false;
    _binding = true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanPort,
        // מאפשר לכמה מתאמים על אותו מחשב לחלוק את הפורט. בשידור broadcast
        // כל אחד מהם מקבל עותק, ולכן שני מופעי אוצריא במחשב אחד עובדים.
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          _handleDatagram(datagram);
        },
        // רק אם זה עדיין הסוקט הפעיל: שגיאה מאוחרת של סוקט שכבר הוחלף
        // אסור לה להפיל את זה שקם במקומו.
        onError: (Object error) {
          if (identical(_socket, socket)) reportSocketFailure(error);
        },
      );
      _socket = socket;
      _lastError = null;
      _deadSends = 0;
      _lastTargets = const [];
      if (_recovering) {
        _recovering = false;
        onLog?.call('הקשר לרשת המקומית חזר');
        onRebound?.call();
      } else {
        onLog?.call('מאזין לרשת המקומית על פורט $lanPort');
      }
      return true;
    } on SocketException catch (e) {
      final reason = 'כשל בהאזנה לפורט $lanPort: ${e.message}';
      // שומר הסף מנסה שוב כל כמה שניות, ולכן מדווחים רק על שינוי מצב —
      // אחרת היומן היה מתמלא באותה שורה עד שהרשת חוזרת.
      if (_lastError != reason) onLog?.call(reason);
      _lastError = reason;
      return false;
    } finally {
      _binding = false;
    }
  }

  /// מטפל בסוקט שנפל, ומיד מנסה להקים אותו מחדש.
  ///
  /// **זה הלב של התיקון.** ב-Windows סוקט UDP מקבל שגיאות אסינכרוניות
  /// שאינן קשורות לקליטה בכלל: שידור אל broadcast של כרטיס בלי מסלול,
  /// או ניתוק Wi-Fi לרגע, מחזירים `network unreachable` (שגיאה 1231) על
  /// הסוקט. ו-Dart, בכל שגיאה כזאת, **סוגר את הסוקט** (ראו
  /// `_RawDatagramSocket` ב-socket_patch.dart של ה-SDK).
  ///
  /// מכאן ואילך המתאם היה נראה בריא לגמרי — ה-API המקומי ממשיך לענות,
  /// והתוסף מציג "מחובר" — אבל שום דבר לא יוצא ולא נכנס: `send` על סוקט
  /// סגור מחזיר 0 בשקט, בלי לזרוק. זו הסיבה ששני מחשבים לא מצאו זה את זה.
  void reportSocketFailure(Object error) {
    if (_disposed) return;
    final wasBound = _socket != null;
    _socket?.close();
    _socket = null;
    _deadSends = 0;
    // הרשת השתנתה תחתינו; היעדים שנמנו לפני כן אינם רלוונטיים.
    _cachedTargets = null;
    _lastError = error is SocketException ? error.message : '$error';
    if (wasBound) {
      _recovering = true;
      onLog?.call('הקשר לרשת נפל ($_lastError) — מתחבר מחדש');
    }
    unawaited(_bind());
  }

  void _handleDatagram(Datagram datagram) {
    final roomCode = roomCodeProvider();
    if (roomCode == null || roomCode.isEmpty) return;
    final message = SyncMessage.decode(
      datagram.data,
      roomCode,
      onClockSkew: _noteClockSkew,
    );
    if (message == null) return;
    _clockSkewMinutes = null;
    _inbound.add(message);
  }

  /// הודעה מהחברותא שנדחתה על פער שעונים. מדווחים פעם אחת ולא על כל
  /// הודעה — הן מגיעות כל 20 שניות, והיומן אינו מקום להצפה.
  void _noteClockSkew(Duration skew) {
    final minutes = skew.inMinutes;
    if (_clockSkewMinutes == minutes) return;
    _clockSkewMinutes = minutes;
    onLog?.call(
      'התקבלה הודעה חתומה מהחברותא אך היא נדחתה: השעונים של שני המחשבים '
      'רחוקים זה מזה ב-${minutes.abs()} דקות. תקנו את השעה במחשב שסוטה.',
    );
  }

  /// משדר הודעה לכל הרשת, בכל היעדים שמחזירה [_targets].
  Future<void> send(SyncMessage message) async {
    final roomCode = roomCodeProvider();
    if (roomCode == null || roomCode.isEmpty) return;

    // סוקט שנפל ועדיין לא קם: מנסים כאן ולא ממתינים לשומר הסף, כדי
    // שהודעה שהמשתמש גרם לה (מעבר דף) תצא מיד כשהרשת חוזרת.
    if (_socket == null) await _bind();
    final socket = _socket;
    if (socket == null) return;

    final targets = await _targets();
    if (targets.isEmpty) {
      // אין כרטיס רשת פעיל. שידור בכל זאת אל 255.255.255.255 היה מפיל
      // את הסוקט בשגיאת "אין מסלול", ולכן פשוט אין למי לשדר עכשיו.
      _noteTargets(targets);
      return;
    }
    _noteTargets(targets);

    final bytes = message.encode(roomCode);
    var delivered = 0;
    for (final target in targets) {
      try {
        delivered += socket.send(bytes, InternetAddress(target), lanPort);
      } on SocketException catch (e) {
        onLog?.call('כשל בשליחה אל $target: ${e.message}');
      }
    }

    if (delivered > 0) {
      _deadSends = 0;
      return;
    }
    // שידור שלם שלא הוציא בייט אחד. ב-Dart זו החתימה של סוקט סגור,
    // שאינו זורק אלא מחזיר 0 — הרשת השקטה שהתגלתה בשטח.
    if (++_deadSends >= deadSendThreshold) {
      reportSocketFailure(
        SocketException('השידור אינו יוצא — הסוקט אינו פעיל'),
      );
    }
  }

  /// מדווח ליומן על יעדי השידור, אך ורק כשהם משתנים. זו שורת האבחון
  /// שמראה בשטח לאיזו רשת המתאם באמת משדר.
  void _noteTargets(List<String> targets) {
    if (_listEquals(targets, _lastTargets)) return;
    _lastTargets = targets;
    onLog?.call(
      targets.isEmpty
          ? 'אין כרטיס רשת פעיל — אין למי לשדר'
          : 'משדר אל ${targets.join(", ")}',
    );
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// כתובת ה-broadcast של הרשת שאליה שייכת [address], או `null` אם אינה
  /// כתובת IPv4 תקינה.
  ///
  /// Dart אינו חושף את מסכת הרשת, ולכן המסכה נגזרת מהכתובת:
  /// - `169.254.x.x` — כתובת link-local, שהיא תמיד /16. זה המצב **כששני
  ///   מחשבים מחוברים בכבל רשת ישר בלי ראוטר**: אין DHCP, ולכן Windows
  ///   נותן לכל צד כתובת כזאת. ב-/24 שגוי ה-broadcast לא היה מגיע לצד השני.
  /// - כל השאר — /24, הנחה שנכונה כמעט בכל רשת ביתית או רשת מוסד קטנה.
  static String? broadcastAddressForIPv4(String address) {
    final octets = address.split('.');
    if (octets.length != 4) return null;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) return null;
    }
    if (octets[0] == '169' && octets[1] == '254') return linkLocalBroadcast;
    return '${octets[0]}.${octets[1]}.${octets[2]}.255';
  }

  /// יעדי השידור עבור קבוצת כתובות IPv4 של כרטיסי הרשת.
  ///
  /// - אין כתובות בכלל — אין יעדים. שידור אל 255.255.255.255 בלי רשת
  ///   מפיל את הסוקט (ראו [reportSocketFailure]), וזה בדיוק המחיר שאסור
  ///   לשלם על מחשב שרק התנתק לרגע.
  /// - יש רשת אמיתית — משדרים אל הכתובת הגלובלית ואל ה-broadcast המכוון
  ///   של כל רשת כזאת. הגלובלית לבדה אינה מספיקה כשיש כמה כרטיסים, כי
  ///   היא יוצאת רק דרך מסלול ברירת המחדל.
  /// - **כתובות link-local נכללות רק כשאין שום רשת אמיתית.** על מחשב
  ///   רגיל הן שייכות לכרטיסים וירטואליים (Wi-Fi Direct, מכונות
  ///   וירטואליות) שאין להם מסלול, ושידור אליהם הוא בדיוק מה שהרג את
  ///   הסוקט. כשהן היחידות — זה חיבור ישיר בכבל בין שני מחשבים, ואז הן
  ///   הרשת היחידה שיש, ובלעדיהן החיבור הזה לא היה עובד כלל.
  static List<String> broadcastTargetsFor(Iterable<String> addresses) {
    final routable = <String>{};
    var hasLinkLocal = false;
    for (final address in addresses) {
      final broadcast = broadcastAddressForIPv4(address);
      if (broadcast == null) continue;
      if (broadcast == linkLocalBroadcast) {
        hasLinkLocal = true;
      } else {
        routable.add(broadcast);
      }
    }
    if (routable.isNotEmpty) {
      return ['255.255.255.255', ...routable];
    }
    return hasLinkLocal ? ['255.255.255.255', linkLocalBroadcast] : const [];
  }

  Future<List<String>> _targets() async {
    final cached = _cachedTargets;
    if (cached != null && _targetsAge.elapsed < targetsCacheTtl) return cached;

    final addresses = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: true,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          addresses.add(address.address);
        }
      }
    } catch (e) {
      onLog?.call('לא ניתן לרשום כרטיסי רשת: $e');
    }
    final targets = broadcastTargetsFor(addresses);
    _cachedTargets = targets;
    _targetsAge
      ..reset()
      ..start();
    return targets;
  }

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    _socket?.close();
    _socket = null;
    await _inbound.close();
  }
}
