import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// כתובת ה-broadcast של רשת link-local (169.254.x.x).
const String linkLocalBroadcast = '169.254.255.255';

/// broadcast מוגבל: היעד היחיד שנקלט אצל היעד **בלי תלות ברשת שלו**.
///
/// broadcast מכוון-רשת (`169.254.255.255`, `192.168.1.255`) נקלט רק אצל מי
/// שיש לו כתובת באותה רשת. חברותא שהכרטיס שלה לא קיבל כתובת, או קיבל כתובת
/// מרשת אחרת, מקבלת את הדטגרמה פיזית וזורקת אותה בשכבת ה-IP — ואז הקישור
/// חד-כיווני: אנחנו שומעים אותה והיא אינה שומעת אותנו.
///
/// זה נשלח **מהסוקט שקשור לכתובת הכרטיס**, ולכן אינו תלוי במסלול ברירת
/// המחדל, וזו הסיבה שהסכנה שתועדה ב-[LanTransport.broadcastRoutesFor] אינה
/// חלה כאן: היא הייתה של שליחה מסוקט כללי. כשל בשליחה אליו אינו מפיל את
/// הסוקט של הכרטיס; ראו [LanTransport.send].
const String globalBroadcast = '255.255.255.255';

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

/// כמה זמן סוקט חייב להחזיק מעמד כדי שנפילתו תזכה לקימה מיידית.
///
/// סוקט שמת מיד אחרי שקם מלמד שהשידור עצמו הוא שהורג אותו, ואז קימה
/// מיידית היא לופ סגור: הסוקט קם, [LanTransport.onRebound] משדר נוכחות,
/// השידור הורג אותו, והוא קם שוב. ביומן בשטח זה נראה כעשרים נפילות
/// בשנייה אחת. מעל הרף הזה מדובר בניתוק רשת אמיתי, ושם קימה מיידית היא
/// בדיוק מה שצריך.
const Duration immediateRebindMinUptime = Duration(seconds: 2);

/// כמה שידורים רצופים שבהם *אף* בייט לא יצא נחשבים לסוקט מת.
///
/// שידור שחוזר 0 הוא בדרך כלל חוצץ מלא לרגע, ולכן לא מגיבים לאחד בודד;
/// שניים ברצף לכל היעדים כבר אומרים שהסוקט אינו שולח יותר כלום.
const int deadSendThreshold = 2;

/// כרטיס רשת ויעד השידור שלו: הכתובת המקומית, וה-broadcast של הרשת שלה.
///
/// **השידור נשלח מסוקט שקשור ל-[local] בדיוק**, ולא מסוקט כללי על
/// `0.0.0.0`. אחרת מערכת ההפעלה בוחרת את הכרטיס היוצא לפי טבלת הניתוב,
/// ובכל מקום שבו כמה כרטיסים חולקים רשת אחת היא בוחרת **אחד** מהם.
///
/// זה אינו מקרה קצה אלא בדיוק המצב האופליין: על מחשב Windows רגיל יש
/// כמה כרטיסים עם כתובת `169.254.x.x` — שני כרטיסי Wi-Fi Direct
/// וירטואליים ועוד אחד של Bluetooth PAN — וכולם באותה רשת `169.254/16`.
/// שידור אחד אל `169.254.255.255` מסוקט כללי יוצא דרך אחד מהם, וכמעט
/// בוודאות לא דרך זה שהחברותא נמצאת בצדו.
typedef BroadcastRoute = ({String local, String broadcast});

/// שידור וקליטה של הודעות חברותא ברשת המקומית, על UDP broadcast.
///
/// אין שרת ואין הגדרת כתובות: כל מתאם משדר לכל הרשת, וכל מתאם מסנן
/// לפי גיבוב קוד החברותא וחתימת ה-HMAC. לכן שני מחשבים מוצאים זה את זה
/// בלי שום קונפיגורציה.
///
/// **ראוטר אינו נדרש, אבל קישור כלשהו כן.** כל דרך שנותנת לשני המחשבים
/// כתובות IPv4 באותה רשת עובדת כאן, ובכולן המתאם מגלה את היעד לבד:
/// ראוטר, נקודה חמה של Windows (הכתובות יוצאות `192.168.137.x`), Wi-Fi
/// Direct, או כבל רשת ישר בין שני המחשבים (ואז `169.254.x.x`, ראו
/// [broadcastAddressForIPv4]). מה ש**אינו** עובד הוא מחשב שאין לו קישור
/// בכלל: כתובת `169.254` על כרטיס וירטואלי שאין בצדו השני אף אחד היא
/// רשת של מחשב אחד, וממילא אין לה למי לשדר.
class LanTransport {
  LanTransport({
    required this.roomCodeProvider,
    this.onLog,
    Duration? rebindMinUptime,
    this.port = lanPort,
    this.addressesProvider,
  }) : rebindMinUptime = rebindMinUptime ?? immediateRebindMinUptime;

  /// מונה את כתובות ה-IPv4 של כרטיסי הרשת. `null` = מנייה אמיתית דרך
  /// `NetworkInterface.list`.
  ///
  /// קיים בשביל בדיקות, וזה תפר שהיה חסר: **מערך הכרטיסים משתנה תוך
  /// ריצה** — כרטיס בלוטות' שמתחבר אחרי עליית המתאם, או נופל בהתעוררות
  /// משינה — וזה בדיוק המסלול המרכזי כאן. בלי הזרקה אין שום דרך לכסות
  /// אותו, ו-[broadcastRoutesFor] לבדו נבדק כפונקציה טהורה על רשימות
  /// סטטיות.
  final Future<List<String>> Function()? addressesProvider;

  /// הפורט שעליו מאזינים ואליו משדרים. פרמטר ולא הקבוע [lanPort] ישירות,
  /// כדי שבדיקות יקבלו פורט משלהן: הפורט האמיתי משותף (`reuseAddress`) עם
  /// כל מתאם אחר שרץ על המחשב, ו-unicast אליו מגיע רק לאחד מהם — כלומר
  /// בדיקה שנשענת עליו נכשלת או עוברת לפי מה שרץ במקרה ברקע.
  ///
  /// `0` = פורט חופשי שהמערכת בוחרת; ראו [boundPort].
  final int port;

  /// הרף שמתחתיו נפילה נחשבת "מת מהשידור" ואינה זוכה לקימה מיידית.
  /// פרמטר ולא קבוע גלובלי, כדי שבדיקות יבדקו את שני הענפים בלי לישון.
  final Duration rebindMinUptime;

  /// מספק את קוד החברותא **הנוכחי**. פונקציה ולא ערך, כי המשתמש יכול
  /// לשנות קוד בזמן ריצה והתעבורה חייבת לעבור לחדר החדש מיד.
  final String? Function() roomCodeProvider;

  final void Function(String message)? onLog;

  /// נקרא אחרי שהסוקט קם מחדש בעקבות נפילה. ה-hub משדר בעקבותיו נוכחות
  /// מיידית, כדי שהחברותא לא תמתין עוד מחזור שלם כדי לראות אותנו שוב.
  void Function()? onRebound;

  RawDatagramSocket? _socket;
  Timer? _watchdog;

  /// הקימה שבתעופה כרגע, אם יש. מונע שתי בנייות מקבילות של הסוקט (שומר
  /// הסף ושידור שנתקל בסוקט מת), **ומאפשר לשניהם להמתין לאותה תוצאה**.
  Future<bool>? _bindInFlight;

  /// אחרי [dispose] אין קמים מחדש — גם לא בעקבות שגיאה שהגיעה באיחור.
  bool _disposed = false;

  /// האם הסוקט נפל מאז שעלה, כלומר הקימה הבאה היא התאוששות ולא עלייה.
  bool _recovering = false;

  String? _lastError;

  /// פער השעונים (בדקות) שבגללו נדחתה הודעה מהחברותא, או `null` אם אין
  /// בעיה כזאת. מתאפס ברגע שהודעה כן מתקבלת.
  int? _clockSkewMinutes;

  /// שלושת המונים שהופכים "אין אף אחד" מניחוש לאבחנה.
  ///
  /// עד עכשיו התוסף לא ידע להבדיל בין שלושה מצבים שנראים זהים לחלוטין
  /// מבחוץ, ושהפתרון לכל אחד מהם אחר לגמרי. המונים האלה מפרידים ביניהם,
  /// והמפתח הוא ש**השידור שלנו חוזר אלינו**: broadcast נקלט גם אצל
  /// השולח, ולכן יש כאן בדיקת לופבק בחינם.
  ///
  /// - [datagramsReceived] אפס — אפילו השידור של עצמנו אינו חוזר. סוקט
  ///   הקליטה חסום, וכמעט תמיד זו חומת האש.
  /// - יש קליטה אך [datagramsFromOthers] אפס — אנחנו משדרים ושומעים את
  ///   עצמנו, אבל אף מחשב אחר לא נשמע. אין קישור בין המחשבים, או שהמתאם
  ///   בצד השני אינו רץ.
  /// - מגיע ממחשב אחר אך [datagramsRejected] גדל ואין חברים — ההודעות
  ///   מגיעות ונזרקות: קוד שאינו זהה, או פער שעונים (שיש לו דיווח משלו).
  int _received = 0;
  int _receivedRemote = 0;
  int _rejected = 0;

  /// דחיות שנבעו **מפער שעונים** ולא מקוד שאינו זהה. נמנות בנפרד כדי
  /// שהאבחון לא יאשים את הקוד: הודעה שנדחתה על זמן כבר עברה אימות
  /// חתימה, כלומר הקוד בשני הצדדים **כן** זהה, וזו בדיוק ההפוכה של מה
  /// שהאבחנה "כמעט בוודאות הקוד אינו זהה" אומרת למשתמש לתקן.
  int _clockRejected = 0;
  String? _lastRemoteSource;

  /// הכתובות של המחשב הזה, לסיווג "הגיע ממחשב אחר". מתעדכן בכל מנייה.
  Set<String> _localAddresses = const {};

  int _deadSends = 0;
  List<BroadcastRoute> _lastRoutes = const [];

  /// כמה זמן הסוקט הנוכחי חי. ראו [immediateRebindMinUptime].
  final Stopwatch _uptime = Stopwatch();

  /// סוקטי השידור, לפי כתובת הכרטיס שהם קשורים אליה. ראו [BroadcastRoute].
  final Map<String, RawDatagramSocket> _senders = {};

  /// קישורי סוקט שידור שבתעופה, לפי כתובת. ראו [_senderFor].
  final Map<String, Future<RawDatagramSocket?>> _senderBinds = {};

  /// כתובות שלא ניתן היה לפתוח עליהן סוקט שידור, ושכבר דווחו ליומן.
  ///
  /// כרטיס **מנותק** שיש לו כתובת — וזה מצבם הרגיל של כרטיסי Wi-Fi Direct
  /// ו-Bluetooth PAN כל עוד לא חובר אליהם אף אחד — אינו מאפשר קישור סוקט.
  /// הניסיון חוזר בכל שידור בכוונה, כדי שברגע שהכרטיס יתחבר השידור יעבור
  /// דרכו מיד; רק הדיווח ליומן נעשה פעם אחת.
  final Set<String> _senderFailures = {};

  /// כתובות שהשידור אל [globalBroadcast] דרכן נכשל, ושכבר דווחו ליומן.
  /// ראו [_sendGlobal] — כשל כזה אינו מונע את השידור המכוון.
  final Set<String> _globalSendFailures = {};

  /// כתובות שהשידור דרכן עובד **כרגע**, כלומר נפתח עליהן סוקט שידור
  /// והוא עוד לא נכשל.
  ///
  /// כרטיס שנמנה אך אינו ניתן לקישור הוא כמעט תמיד Wi-Fi Direct או
  /// Bluetooth PAN שאין בצדו אף אחד. הוא נשאר ברשימת הניסיונות בכוונה
  /// (ברגע שיתחבר השידור יעבור דרכו מיד), אבל מוצג לתוסף כמי שאינו משדר
  /// — אחרת שורת הקישורים, שכל תפקידה להשוות שני מחשבים, מציגה שלושה
  /// כרטיסים מתים.
  ///
  /// **הכתובת מוסרת מכאן ברגע שהקישור נכשל, וזה העיקר.** קודם לכן זו
  /// הייתה קבוצת "נקשר פעם אי פעם" שלא נוקתה לעולם, ולכן קישור בלוטות'
  /// שעבד ואחר כך נפל — מה שקורה ב-Windows בכל התעוררות משינה — המשיך
  /// להיות מוצג כמשדר. זו היפוכה של הבדיקה החד-משמעית שהתיעוד מבטיח:
  /// הכרטיס המנותק הכריז על עצמו כקישור חי, והמשתמש נשלח לחפש את התקלה
  /// בקוד החברותא.
  final Set<String> _sendingNow = {};

  /// מסלולי השידור שנמנו לאחרונה, ובן כמה הם. ראו [targetsCacheTtl].
  List<BroadcastRoute>? _cachedRoutes;
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

  /// הפורט שהסוקט קשור אליו בפועל, או `null` כשאין סוקט. שונה מ-[port]
  /// רק כשביקשו `0`, כלומר בבדיקות.
  int? get boundPort => _socket?.port;

  /// כמה דטגרמות נקלטו על [port] מאז העלייה — כולל השידור של עצמנו
  /// שחוזר. אפס = הקליטה חסומה. ראו [_received].
  int get datagramsReceived => _received;

  /// מתוכן, כמה הגיעו מכתובת שאינה של המחשב הזה.
  int get datagramsFromOthers => _receivedRemote;

  /// כמה נקלטו ונזרקו בפענוח (חדר אחר, או חתימה שגויה). **אינו כולל
  /// דחיות על פער שעונים** — אלה ב-[datagramsClockRejected].
  int get datagramsRejected => _rejected;

  /// כמה נדחו על פער שעונים, כלומר אחרי שהחתימה כן אומתה. ראו
  /// [_clockRejected].
  int get datagramsClockRejected => _clockRejected;

  /// כתובת ה-IP האחרונה שממנה נקלטה דטגרמה ממחשב אחר, או `null`.
  String? get lastRemoteSource => _lastRemoteSource;

  /// מסלולי השידור הנוכחיים, לתצוגה בתוסף. השוואת השורה הזאת בין שני
  /// מחשבים היא הדרך המהירה לראות אם הם באמת על אותו קישור.
  List<BroadcastRoute> get routes => _lastRoutes;

  /// האם דרך [local] יוצא שידור **כרגע**. ראו [_sendingNow] — כרטיס
  /// שנמנה אך אינו משדר הוא רעש בשורת הקישורים, לא קישור.
  bool isSending(String local) => _sendingNow.contains(local);

  Future<bool> start() async {
    _watchdog ??= Timer.periodic(socketWatchdogInterval, (_) {
      unawaited(_bind());
      // **מונים את הכרטיסים גם כשאין זיווג.** [send] יוצא לפני המנייה
      // כשאין קוד חדר, ובלי המנייה כאן כרטיס בלוטות' שהתחבר אחרי עליית
      // המתאם לא היה מזוהה כלל — והתוסף היה מציג את שורת הקישורים כפי
      // שנמנתה פעם אחת ב-[start], או ריקה לגמרי אחרי קימה מחדש.
      unawaited(_routes());
    });
    final bound = await _bind();
    // מונים את הכרטיסים מיד ולא רק בשידור הראשון, כדי שסיווג "הגיע
    // ממחשב אחר" יהיה נכון גם לדטגרמה הראשונה שתיכנס.
    await _routes();
    return bound;
  }

  /// בונה את הסוקט אם אין. מחזיר האם יש סוקט חי בסוף הפעולה.
  ///
  /// **קימה אחת בלבד בתעופה, וכל הקוראים ממתינים לאותה קימה.** קודם לכן
  /// קורא שני קיבל `false` מיד, ולכן [send] היה יוצא בלי לשדר בדיוק
  /// בשנייה שבה שומר הסף החזיר את הסוקט לחיים — ומעבר דף שהמשתמש עשה
  /// היה אובד עד השידור הבא.
  Future<bool> _bind() {
    if (_disposed) return Future.value(false);
    if (_socket != null) return Future.value(true);
    final inFlight = _bindInFlight;
    if (inFlight != null) return inFlight;
    final started = _doBind();
    _bindInFlight = started;
    return started.whenComplete(() {
      if (identical(_bindInFlight, started)) _bindInFlight = null;
    });
  }

  Future<bool> _doBind() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        // מאפשר לכמה מתאמים על אותו מחשב לחלוק את הפורט. בשידור broadcast
        // כל אחד מהם מקבל עותק, ולכן שני מופעי אוצריא במחשב אחד עובדים.
        reuseAddress: true,
      );
      // [dispose] שקרה בזמן שהקישור היה בתעופה. בלי הבדיקה הזאת הסוקט
      // אינו נסגר לעולם (הטיימר כבר בוטל), [isBound] חוזר לאמת אחרי
      // dispose, והדטגרמה הראשונה מגיעה ל-StreamController סגור.
      if (_disposed) {
        socket.close();
        return false;
      }
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
        // **זרם שנסגר בלי שגיאה.** בלעדיו `_socket` נשאר לא-null, [isBound]
        // חוזר אמת, התוסף מציג "מחובר" — ושום דבר אינו נקלט עוד. השידור
        // ממשיך לצאת מסוקטי השידור הנפרדים, ולכן גם [deadSendThreshold]
        // אינו תופס את זה: שקט חד-כיווני שנראה תקין לגמרי.
        onDone: () {
          if (identical(_socket, socket)) {
            reportSocketFailure(
              SocketException('סוקט הקליטה נסגר בלי שגיאה'),
            );
          }
        },
      );
      _socket = socket;
      _lastError = null;
      _deadSends = 0;
      _uptime
        ..reset()
        ..start();
      _lastRoutes = const [];
      if (_recovering) {
        _recovering = false;
        onLog?.call('הקשר לרשת המקומית חזר');
        onRebound?.call();
      } else {
        onLog?.call('מאזין לרשת המקומית על פורט ${_socket?.port ?? port}');
      }
      return true;
    } on SocketException catch (e) {
      final reason = 'כשל בהאזנה לפורט $port: ${e.message}';
      // שומר הסף מנסה שוב כל כמה שניות, ולכן מדווחים רק על שינוי מצב —
      // אחרת היומן היה מתמלא באותה שורה עד שהרשת חוזרת.
      if (_lastError != reason) onLog?.call(reason);
      _lastError = reason;
      return false;
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
    // סוקט שהחזיק פחות מהרף מת מהשידור ולא מהרשת, וקימה מיידית שלו היא
    // הלופ שמתואר ב-[immediateRebindMinUptime]. שומר הסף ינסה בעוד
    // [socketWatchdogInterval], וזה גבול עליון בריא לקצב הניסיונות.
    final shortLived = wasBound && _uptime.elapsed < rebindMinUptime;
    _uptime.stop();
    _socket?.close();
    _socket = null;
    _deadSends = 0;
    // הרשת השתנתה תחתינו; המסלולים שנמנו לפני כן אינם רלוונטיים, וגם
    // סוקטי השידור שנקשרו לכתובות שלהם.
    _cachedRoutes = null;
    for (final local in _senders.keys.toList()) {
      _dropSender(local);
    }
    _lastError = error is SocketException ? error.message : '$error';
    if (wasBound) {
      _recovering = true;
      onLog?.call(
        shortLived
            ? 'הקשר לרשת נפל מיד אחרי שקם ($_lastError) — ממתין לפני ניסיון נוסף'
            : 'הקשר לרשת נפל ($_lastError) — מתחבר מחדש',
      );
    }
    if (!shortLived) unawaited(_bind());
  }

  /// מאפס את מוני האבחון. נקרא בהחלפת חדר.
  ///
  /// **בלי זה סולם ארבע האבחנות חד-כיווני לכל אורך חיי התהליך.** המונים
  /// הצטברו מהעלייה ולא אופסו לעולם, ולכן אחרי שנקלטה דטגרמה אחת ממחשב
  /// אחר, האבחנה "השידור שלכם יוצא וחוזר, אך שום הודעה ממחשב אחר לא
  /// הגיעה" לא הייתה מוצגת שוב אף פעם. וזה בדיוק מסלול הבלוטות': הקישור
  /// נופל בכל התעוררות משינה, ואחרי הנפילה התוסף היה מדלג לאבחנה הבאה
  /// ("הודעות מגיעות אך נדחות — הקוד אינו זהה") ושולח את המשתמש לבדוק
  /// את הקוד במקום לחבר מחדש את ה-PAN.
  void resetDiagnostics() {
    _received = 0;
    _receivedRemote = 0;
    _rejected = 0;
    _clockRejected = 0;
    _lastRemoteSource = null;
    _clockSkewMinutes = null;
  }

  void _handleDatagram(Datagram datagram) {
    // המונים נספרים לפני כל סינון, וגם כשאין קוד חברותא: השאלה שהם
    // עונים עליה היא "מה בכלל מגיע לסוקט", ולא "מה קיבלנו".
    _received++;
    final source = datagram.address.address;
    // loopback הוא המחשב הזה בהגדרה. מניית הכרטיסים מדלגת עליו (ובצדק —
    // אין לו broadcast לשדר אליו), ולכן בלי התנאי הזה דטגרמה מ-127.0.0.1
    // הייתה נספרת כ"ממחשב אחר" ומזייפת את האבחנה.
    final remote =
        !datagram.address.isLoopback && !_localAddresses.contains(source);
    if (remote) {
      _receivedRemote++;
      _lastRemoteSource = source;
    }

    final roomCode = roomCodeProvider();
    if (roomCode == null || roomCode.isEmpty) return;
    var clockRejected = false;
    final message = SyncMessage.decode(
      datagram.data,
      roomCode,
      onClockSkew: (skew) {
        clockRejected = true;
        _noteClockSkew(skew);
      },
    );
    if (message == null) {
      // דטגרמה שלנו שחזרה נזרקת ב-hub ולא כאן, ולכן דחייה של דטגרמה
      // מרוחקת היא תמיד סימן אמיתי: קוד אחר, חתימה, או זמן. **ופער
      // שעונים נמנה בנפרד** — ראו [_clockRejected]: הודעה שנדחתה עליו
      // כבר אומתה בחתימה, כלומר הקוד זהה, והאבחנה "הקוד אינו זהה"
      // הייתה שולחת את המשתמש לתקן דבר תקין.
      if (remote) {
        if (clockRejected) {
          _clockRejected++;
        } else {
          _rejected++;
        }
      }
      return;
    }
    // **רק הודעה ממחשב אחר מנקה את אזהרת השעונים.** הדטגרמה שלנו חוזרת
    // אלינו מה-broadcast, והיא תמיד טרייה — היא נחתמה בשעון הזה עצמו.
    // ניקוי בעקבותיה היה מוחק את האזהרה כל 20 שניות, וכך פער שעונים
    // שמפיל את *כל* הודעות החברותא נראה בתוסף כאילו אינו קיים.
    if (remote) _clockSkewMinutes = null;
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

  /// משדר הודעה לכל הרשת, בכל המסלולים שמחזירה [_routes].
  ///
  /// **כל מסלול משודר מסוקט שקשור לכתובת הכרטיס שלו**, ולא מהסוקט הכללי.
  /// ראו [BroadcastRoute] להסבר למה זה הכרחי.
  Future<void> send(SyncMessage message) async {
    final roomCode = roomCodeProvider();
    if (roomCode == null || roomCode.isEmpty) return;

    // סוקט שנפל ועדיין לא קם: מנסים כאן ולא ממתינים לשומר הסף, כדי
    // שהודעה שהמשתמש גרם לה (מעבר דף) תצא מיד כשהרשת חוזרת.
    if (_socket == null) await _bind();
    if (_socket == null) return;

    final routes = await _routes();
    _noteRoutes(routes);
    // אין כרטיס רשת פעיל. שידור בכל זאת אל 255.255.255.255 היה מפיל את
    // הסוקט בשגיאת "אין מסלול", ולכן פשוט אין למי לשדר עכשיו.
    if (routes.isEmpty) return;

    final bytes = message.encode(roomCode);
    var delivered = 0;
    var liveSenders = 0;
    for (final route in routes) {
      final sender = await _senderFor(route.local);
      if (sender == null) continue;
      liveSenders++;
      try {
        final sent = sender.send(bytes, InternetAddress(route.broadcast), port);
        delivered += sent;
        // סוקט סגור אינו זורק אלא מחזיר 0 בשקט. זורקים אותו כאן, והשידור
        // הבא יבנה אותו מחדש — במקום כרטיס שנשאר אילם לנצח.
        if (sent == 0) _dropSender(route.local);
      } on SocketException catch (e) {
        onLog?.call(
          'כשל בשליחה אל ${route.broadcast} מ-${route.local}: ${e.message}',
        );
        _dropSender(route.local);
      }
      // ואותה הודעה גם אל ה-broadcast המוגבל, מאותו כרטיס. ראו
      // [globalBroadcast]: זה מה שמגיע לחברותא שאינה באותה רשת.
      delivered += _sendGlobal(route.local, sender, bytes);
    }

    if (delivered > 0) {
      _deadSends = 0;
      return;
    }
    // **אף כרטיס לא נקשר, ולכן אין כאן מה להסיק על סוקט הקליטה.** זה
    // המצב הרגיל של מחשב בלי ראוטר שהבלוטות' שלו עוד לא חובר: הכתובת
    // `169.254` של ה-PAN כן נמנית (אימתנו — `NetworkInterface.list`
    // מחזיר אותה), אבל הקישור אליה נכשל ב-`WSAEADDRNOTAVAIL` כל עוד היא
    // `Tentative`. הענישה של סוקט הקליטה כאן הייתה סוגרת סוקט שעובד
    // מושלם, מדליקה את [lastError], ומכריזה בתוסף "המתאם אינו מאזין
    // לקישור" — ואז קמה, משדרת נוכחות, נכשלת שוב, בלופ של 40 שניות.
    // התקלה האמיתית היא שאין קישור, וזה מה שהתוסף צריך לומר.
    if (liveSenders == 0) {
      _deadSends = 0;
      return;
    }
    // שידור שלם שלא הוציא בייט אחד, **מסוקטים שכן נקשרו**. זה כבר אינו
    // כרטיס בודד שנפל אלא שקט מלא, ולכן מקימים גם את סוקט הקליטה.
    if (++_deadSends >= deadSendThreshold) {
      reportSocketFailure(
        SocketException('השידור אינו יוצא — הסוקט אינו פעיל'),
      );
    }
  }

  /// סוקט השידור של [local], ובונה אותו אם עוד אין. `null` = לא ניתן
  /// לפתוח סוקט על הכתובת הזאת (כרטיס שנעלם בין המנייה לשידור).
  /// **קישור אחד בלבד בתעופה לכל כתובת, וכל הקוראים ממתינים לאותו קישור.**
  /// בלי זה שתי שליחות חופפות לאותו כרטיס — טיימר הנוכחות מול שידור מיקום
  /// במעבר דף, או הלופ שמשדר את מנות השולחן — שתיהן רואות `null`, שתיהן
  /// קושרות סוקט, וההקצאה השנייה מנטרת את הראשון: הוא אינו נסגר לעולם
  /// ומחזיק פורט UDP ומנוי `listen` עד סוף התהליך.
  Future<RawDatagramSocket?> _senderFor(String local) {
    final existing = _senders[local];
    if (existing != null) return Future.value(existing);
    final inFlight = _senderBinds[local];
    if (inFlight != null) return inFlight;
    final started = _bindSender(local);
    _senderBinds[local] = started;
    return started.whenComplete(() {
      if (identical(_senderBinds[local], started)) _senderBinds.remove(local);
    });
  }

  Future<RawDatagramSocket?> _bindSender(String local) async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress(local), 0);
      if (_disposed) {
        socket.close();
        return null;
      }
      socket.broadcastEnabled = true;
      // סוקט שידור אינו קולט דבר — הקליטה כולה על הסוקט הכללי שעל פורט
      // [lanPort]. ההאזנה כאן היא רק כדי לתפוס שגיאה אסינכרונית, שבעקבותיה
      // Dart סוגר את הסוקט; אז זורקים אותו והשידור הבא בונה חדש.
      socket.listen(
        (_) {},
        onError: (Object _) {
          if (identical(_senders[local], socket)) _dropSender(local);
        },
      );
      _senders[local] = socket;
      _senderFailures.remove(local);
      _sendingNow.add(local);
      return socket;
    } on SocketException catch (e) {
      // הכרטיס אינו מאפשר קישור **כרגע**, ולכן אינו משדר — גם אם בעבר
      // כן היה. ראו [_sendingNow].
      _sendingNow.remove(local);
      // פעם אחת לכל כתובת, עד שרשימת המסלולים תשתנה. ראו [_senderFailures].
      if (_senderFailures.add(local)) {
        onLog?.call(
          'אין שידור דרך $local — כנראה כרטיס שאינו מחובר (${e.message})',
        );
      }
      return null;
    }
  }

  /// משדר אל [globalBroadcast] דרך הכרטיס [local]. מחזיר כמה בייטים יצאו.
  ///
  /// **כשל כאן אינו מפיל את הסוקט של הכרטיס.** ה-broadcast המכוון הוא
  /// היעד שאפשר לסמוך עליו, וזה תוספת כיסוי; כרטיס שמערכת ההפעלה מסרבת
  /// לשלוח דרכו אל `255.255.255.255` צריך להמשיך לשדר אל הרשת שלו כרגיל.
  int _sendGlobal(String local, RawDatagramSocket sender, List<int> bytes) {
    // השליחה המכוונת שקדמה לזה עלולה הייתה לזרוק את הסוקט. סוקט סגור
    // אינו זורק אלא מחזיר 0, וזה היה נספר כשידור שלא יצא.
    if (!identical(_senders[local], sender)) return 0;
    try {
      final sent = sender.send(bytes, InternetAddress(globalBroadcast), port);
      if (sent > 0) _globalSendFailures.remove(local);
      return sent;
    } on SocketException catch (e) {
      // פעם אחת לכל כתובת, כמו [_senderFailures]: זה משודר כל 20 שניות.
      if (_globalSendFailures.add(local)) {
        onLog?.call(
          'אין שידור אל $globalBroadcast דרך $local (${e.message}) — '
          'ממשיך לשדר אל ה-broadcast של הרשת',
        );
      }
      return 0;
    }
  }

  void _dropSender(String local) {
    _senders.remove(local)?.close();
    // הסוקט נזרק, ולכן דרך הכתובת הזאת לא יוצא שידור עד שיקום מחדש.
    // זה מכסה את כל המסלולים שמגיעים לכאן: שליחה שהחזירה 0, שגיאה
    // אסינכרונית, כרטיס שנעלם מהמנייה, ונפילת סוקט הקליטה.
    _sendingNow.remove(local);
  }

  /// מדווח ליומן על מסלולי השידור, אך ורק כשהם משתנים. זו שורת האבחון
  /// שמראה בשטח לאיזו רשת המתאם באמת משדר, **ומאיזה כרטיס** — וזה מה
  /// שמאפשר להשוות שני מחשבים ולראות אם הם באמת על אותו קישור.
  void _noteRoutes(List<BroadcastRoute> routes) {
    if (_listEquals(routes, _lastRoutes)) return;
    _lastRoutes = routes;
    // הרשת השתנתה, ולכן כרטיס שנכשל קודם ראוי לדיווח מחודש אם ייכשל שוב.
    _senderFailures.clear();
    _globalSendFailures.clear();
    onLog?.call(
      routes.isEmpty
          ? 'אין כרטיס רשת פעיל — אין למי לשדר'
          : 'משדר אל ${routes.map((r) => "${r.broadcast} + $globalBroadcast (מ-${r.local})").join(", ")}',
    );
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
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
  /// **כל כתובת מקבלת את ה-broadcast המכוון של הרשת שלה, וזה הכול.** שני
  /// הכללים שהיו כאן קודם — הוספת `255.255.255.255`, וזריקת כתובות
  /// link-local כשיש רשת אמיתית — נבדקו בשטח ושניהם התגלו כמזיקים:
  ///
  /// - `255.255.255.255` **אינו מוסיף כיסוי**: הוא יוצא רק דרך מסלול
  ///   ברירת המחדל, כלומר בדיוק דרך הכרטיס שה-broadcast המכוון שלו כבר
  ///   ברשימה. לעומת זאת על מחשב **בלי** מסלול ברירת מחדל — מחשב שלא מצא
  ///   DHCP, שהוא בדיוק המצב של חיבור בין שני מחשבים בלי ראוטר — השליחה
  ///   אליו מחזירה "אין מסלול", Dart סוגר בעקבותיה את הסוקט (ראו
  ///   [reportSocketFailure]), והוא קם ומת שוב ושוב. ביומן בשטח זה נראה
  ///   כעשרות נפילות בשנייה, וסנכרון שאינו עובד לעולם.
  /// - כתובת link-local **אינה** הורגת את הסוקט. זו הייתה ההנחה כאן, והיא
  ///   נבדקה ונשללה: שידור אל `169.254.255.255` ממחשב שמחובר ל-Wi-Fi עובר
  ///   בשלום, כי לכרטיסים האלה יש מסלול on-link. זריקתה דווקא הזיקה —
  ///   היא ביטלה את החיבור הישיר בכבל בכל פעם שהמחשב היה גם על Wi-Fi,
  ///   כלומר הפכה את הסנכרון לתלוי ראוטר בפועל.
  ///
  /// כל כתובת מקבלת מסלול משלה — גם שתי כתובות באותה רשת. הן שני כרטיסים
  /// שונים (או Wi-Fi שיש לו שתי כתובות), וכל אחד מהם צריך לשדר בעצמו;
  /// עותק כפול אצל החברותא נזרק שם ממילא לפי מזהה השולח והמונה.
  ///
  /// אין כתובות בכלל — אין מסלולים, ואז [send] אינו נוגע בסוקט.
  static List<BroadcastRoute> broadcastRoutesFor(Iterable<String> addresses) {
    final routes = <BroadcastRoute>[];
    final seen = <String>{};
    for (final address in addresses) {
      final broadcast = broadcastAddressForIPv4(address);
      if (broadcast == null) continue;
      if (!seen.add(address)) continue;
      routes.add((local: address, broadcast: broadcast));
    }
    return routes;
  }

  Future<List<BroadcastRoute>> _routes() async {
    final cached = _cachedRoutes;
    if (cached != null && _targetsAge.elapsed < targetsCacheTtl) return cached;

    final addresses = <String>[];
    try {
      final provider = addressesProvider;
      if (provider != null) {
        addresses.addAll(await provider());
      } else {
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
      }
    } catch (e) {
      onLog?.call('לא ניתן לרשום כרטיסי רשת: $e');
      // **מנייה שנכשלה אינה "אין כתובות".** דריסת [_localAddresses]
      // בקבוצה ריקה כאן הייתה מסווגת את הדטגרמות שלנו־עצמנו שחוזרות
      // מה-broadcast כ"הגיעו ממחשב אחר": [datagramsFromOthers] היה עולה,
      // [lastRemoteSource] היה מציג את הכתובת שלנו, וההודעה שלנו הייתה
      // מוחקת את אזהרת פער השעונים. כלומר האבחון היה מצביע על הסיבה
      // הלא-נכונה בדיוק כשהרשת מתנדנדת. משאירים את מה שנמנה לאחרונה.
      return _cachedRoutes ?? _lastRoutes;
    }
    final routes = broadcastRoutesFor(addresses);
    _localAddresses = addresses.toSet();
    // המסלולים מדווחים כאן ולא רק ב-[send], כדי שהתוסף יראה את הקישור
    // גם לפני השידור הראשון ואפילו כשהמתאם אינו מזווג.
    _noteRoutes(routes);
    // כרטיס שנעלם מהמנייה — הסוקט שנקשר לכתובתו כבר אינו תקף, וסוקט
    // כזה נשאר תפוס לנצח בלי הסגירה הזאת.
    final live = routes.map((route) => route.local).toSet();
    for (final gone in _senders.keys.where((k) => !live.contains(k)).toList()) {
      _dropSender(gone);
    }
    _cachedRoutes = routes;
    _targetsAge
      ..reset()
      ..start();
    return routes;
  }

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    _socket?.close();
    _socket = null;
    for (final local in _senders.keys.toList()) {
      _dropSender(local);
    }
    await _inbound.close();
  }
}
