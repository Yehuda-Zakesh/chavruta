import 'dart:convert';

import 'package:crypto/crypto.dart';

/// גרסת הפרוטוקול על החוט. מתאם שמקבל גרסה אחרת מתעלם מההודעה.
const int protocolVersion = 1;

/// פורט ה-UDP שעליו כל המתאמים ברשת מדברים. חייב להיות זהה בכל המחשבים.
const int lanPort = 45870;

/// טווח הפורטים שהמתאם מנסה עבור שרת ה-HTTP המקומי (loopback בלבד).
/// התוסף סורק את אותו טווח כדי למצוא את המתאם.
const int localApiFirstPort = 45871;
const int localApiLastPort = 45875;

/// חלון הזמן שבו הודעה נחשבת טרייה. מגן מפני replay של הודעה שנקלטה
/// ברשת ונשלחה שוב מאוחר יותר.
const Duration freshnessWindow = Duration(minutes: 5);

/// כמה פריטי שולחן נשלחים בהודעה אחת.
///
/// הקישור המיועד הוא Bluetooth PAN, שה-MTU שלו כשל Ethernet — datagram
/// גדול ממנו מתפצל ל-IP fragments, וכל fragment שאובד מפיל את ההודעה
/// **כולה**. שנים-עשר פריטים הם כ-900 בייטים עם המעטפת, כלומר הודעה
/// שנשלחת תמיד כמנה אחת.
///
/// הפיצול חינם כאן משום שמיזוג השולחן הוא **לפי פריט**: לכל ספר יש
/// חותמת משלו, ולכן אין סדר בין מנות ואין תלות ביניהן. מנה שאבדה תגיע
/// שוב בשידור המלא הבא.
const int maxTabsPerMessage = 12;

/// גבול עליון על מספר הספרים שהמתאם מוכן לזכור בשולחן. מגן מפני שולחן
/// עבודה חריג (או הודעה זדונית) שינפח זיכרון ותעבורה.
const int maxTrackedTabs = 60;

enum SyncMessageType {
  /// עדכון מיקום קריאה.
  location,

  /// נוכחות: "אני כאן", לרשימת המחוברים. אינו משנה מיקום.
  presence,

  /// יציאה מסודרת מהחברותא.
  farewell,

  /// פריטים של השולחן המשותף. ראו [DeskEntry] ואת [maxTabsPerMessage].
  desk;

  String get wire => switch (this) {
    SyncMessageType.location => 'loc',
    SyncMessageType.presence => 'hi',
    SyncMessageType.farewell => 'bye',
    SyncMessageType.desk => 'desk',
  };

  static SyncMessageType? fromWire(String value) => switch (value) {
    'loc' => SyncMessageType.location,
    'hi' => SyncMessageType.presence,
    'bye' => SyncMessageType.farewell,
    'desk' => SyncMessageType.desk,
    _ => null,
  };
}

/// מיקום קריאה באוצריא.
///
/// הזהות היא [bookId] — מזהה הספר הטקסטואלי של אוצריא (שם הספר), ולא
/// המזהה המספרי מה-DB. זה מכוון: המזהה המספרי שונה בין מחשב למחשב לפי
/// סדר האינדוקס של הספרייה, ולכן אינו שמיש לסנכרון בין מכשירים.
class SyncLocation {
  const SyncLocation({required this.bookId, required this.index, this.ref});

  final String bookId;
  final int index;

  /// תיאור קריא של המיקום ("ברכות, דף ד"). לתצוגה בלבד.
  final String? ref;

  bool sameSpotAs(SyncLocation? other) =>
      other != null && other.bookId == bookId && other.index == index;

  Map<String, Object?> toJson() => {'bookId': bookId, 'index': index, 'ref': ref};

  static SyncLocation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final index = raw['index'];
    if (bookId is! String || bookId.isEmpty) return null;
    if (index is! int || index < 0) return null;
    final ref = raw['ref'];
    return SyncLocation(
      bookId: bookId,
      index: index,
      ref: ref is String && ref.isNotEmpty ? ref : null,
    );
  }

  @override
  String toString() => 'SyncLocation($bookId#$index)';
}

/// פריט בשולחן העבודה המשותף: ספר, והאם הוא פתוח.
///
/// **זהות הפריט היא הספר בלבד** ([bookId], כלומר שם הספר — מאותה סיבה
/// שב-[SyncLocation]). האינדקס הוא רמז היכן לפתוח, ולא חלק מהזהות: שני
/// הצדדים כמעט תמיד נמצאים בעמודים שונים באותו ספר, ואילו האינדקס היה
/// בזהות, כל גלילה הייתה נראית כספר חדש ופותחת עוד טאב.
///
/// אוצריא מזהה טאב לתוסף באינדקס במערך `openTabs` בלבד, ואינדקס כזה
/// שונה בין שני המחשבים; לכן הוא אינו עובר על החוט כלל.
///
/// ## למה יש כאן חותמת, ולמה [open] ולא רק "קיים"
///
/// לשני הצדדים יש שולחן אחד משותף, ושניהם כותבים אליו. בלי חותמת אין
/// דרך להבדיל בין "החברותא פתחה ספר חדש" לבין "אני סגרתי ספר שהיה
/// פתוח" — בשני המקרים אחת הרשימות ארוכה מהשנייה, ושתי הפרשנויות
/// הפוכות זו לזו. לכן כל ספר נושא את **הפעולה האחרונה שנעשתה בו**:
/// מי קבע, מתי, ומה. המאוחרת מנצחת, ושני הצדדים מתכנסים לאותו שולחן
/// בלי קשר לסדר שבו ההודעות הגיעו.
///
/// סגירה נרשמת ומשודרת כבר היום, גם כשאין עדיין דרך *לבצע* אותה בצד
/// השני: לאוצריא אין `reader.closeTab`. כשהיא תתווסף, הצד המבצע נדלק
/// ואין שינוי בפרוטוקול.
class DeskEntry {
  const DeskEntry({
    required this.bookId,
    required this.stamp,
    required this.by,
    this.index = 0,
    this.open = true,
  });

  final String bookId;

  /// היכן לפתוח את הספר. רמז בלבד.
  final int index;

  /// האם הספר פתוח בשולחן המשותף. `false` = מישהו סגר אותו.
  final bool open;

  /// חותמת הפעולה. ראו [SyncHub] — זהו שעון לוגי-היברידי, ולא שעון
  /// הקיר: מחשב שהשעון שלו סוטה היה מנצח בכל הכרעה לנצח.
  final int stamp;

  /// מזהה המכשיר שקבע את המצב הזה. מכריע בין שתי פעולות באותה חותמת,
  /// כדי ששני הצדדים יגיעו לאותה תוצאה גם בתיקו.
  final String by;

  /// מפתח הזהות. ראו את התיעוד של המחלקה.
  String get key => bookId;

  /// האם [other] גובר על הפריט הזה. מאוחר יותר מנצח; בתיקו מכריע
  /// מזהה המכשיר, ובלבד שההכרעה תהיה זהה בשני הצדדים.
  bool supersededBy(DeskEntry other) =>
      other.stamp > stamp || (other.stamp == stamp && other.by.compareTo(by) > 0);

  DeskEntry copyWith({int? index, bool? open, int? stamp, String? by}) => DeskEntry(
    bookId: bookId,
    index: index ?? this.index,
    open: open ?? this.open,
    stamp: stamp ?? this.stamp,
    by: by ?? this.by,
  );

  /// מפתחות קצרים, כי כל פריט נוסע ב-datagram יחיד ברשת בלוטות'.
  Map<String, Object?> toJson() => {
    'b': bookId,
    'i': index,
    'o': open,
    's': stamp,
    'w': by,
  };

  static DeskEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bookId = raw['b'];
    final stamp = raw['s'];
    final by = raw['w'];
    if (bookId is! String || bookId.isEmpty) return null;
    if (stamp is! int || stamp < 0) return null;
    if (by is! String || by.isEmpty) return null;
    final index = raw['i'];
    final open = raw['o'];
    return DeskEntry(
      bookId: bookId,
      index: index is int && index >= 0 ? index : 0,
      open: open is bool ? open : true,
      stamp: stamp,
      by: by,
    );
  }

  /// מפענח רשימת פריטים, בלי כפילויות ובגבול [maxTrackedTabs].
  static List<DeskEntry> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    final entries = <DeskEntry>[];
    for (final item in raw) {
      final entry = DeskEntry.fromJson(item);
      if (entry == null || !seen.add(entry.key)) continue;
      entries.add(entry);
      if (entries.length >= maxTrackedTabs) break;
    }
    return entries;
  }

  @override
  String toString() => 'DeskEntry($bookId, ${open ? "פתוח" : "סגור"})';
}

/// הודעה על החוט. קוד החברותא עצמו **אינו** נשלח — נשלחים גיבוב שלו
/// (לסינון מהיר) וחתימת HMAC (להוכחת ידיעת הקוד ולמניעת שינוי בדרך).
class SyncMessage {
  const SyncMessage({
    required this.type,
    required this.roomHash,
    required this.senderId,
    required this.senderName,
    required this.timestampMs,
    required this.sequence,
    this.location,
    this.entries = const [],
  });

  final SyncMessageType type;
  final String roomHash;
  final String senderId;
  final String senderName;
  final int timestampMs;
  final int sequence;
  final SyncLocation? location;

  /// פריטי שולחן שהשולח מדווח עליהם. ריק בכל הודעה שאינה [SyncMessageType.desk].
  final List<DeskEntry> entries;

  /// גיבוב קוד החברותא — 16 תווים הקסה. מזהה את החדר בלי לחשוף את הקוד.
  static String hashRoomCode(String normalizedRoomCode) =>
      sha256.convert(utf8.encode('chavruta-room:$normalizedRoomCode')).toString().substring(0, 16);

  /// הצורה הקנונית שעליה נחתמת החתימה. סדר המפתחות קבוע בקוד, ולכן
  /// שני צדדים שמריצים את אותו קוד מייצרים בדיוק את אותם בייטים.
  ///
  /// **`desk` נכנס רק כשיש פריטים, וזה מכוון.** מפתח שהיה נוסף תמיד היה
  /// משנה את הבייטים שעליהם נחתמת כל הודעת מיקום, ומתאם בגרסה קודמת היה
  /// דוחה את החתימה — כלומר שדרוג של מחשב אחד בלבד היה משתיק את הסנכרון
  /// כולו. כך הודעות המיקום נשארות זהות לבית, ומתאם ישן שמקבל הודעת
  /// שולחן פשוט אינו מכיר את הסוג ומתעלם ממנה.
  Map<String, Object?> _canonical() => {
    'v': protocolVersion,
    't': type.wire,
    'room': roomHash,
    'src': senderId,
    'name': senderName,
    'ts': timestampMs,
    'seq': sequence,
    'loc': location?.toJson(),
    if (entries.isNotEmpty) 'desk': entries.map((e) => e.toJson()).toList(),
  };

  static String _sign(Map<String, Object?> canonical, String normalizedRoomCode) {
    final mac = Hmac(sha256, utf8.encode('chavruta-sig:$normalizedRoomCode'));
    return mac.convert(utf8.encode(jsonEncode(canonical))).toString().substring(0, 32);
  }

  /// מקודד לבייטים לשליחה ב-UDP, כולל חתימה.
  List<int> encode(String normalizedRoomCode) {
    final canonical = _canonical();
    return utf8.encode(jsonEncode({...canonical, 'sig': _sign(canonical, normalizedRoomCode)}));
  }

  /// מפענח ומאמת. מחזיר `null` לכל הודעה שאינה שייכת לחדר הזה, אינה
  /// חתומה נכון, או אינה טרייה — בשקט, כי ברשת משותפת זה מצב רגיל.
  /// [onClockSkew] נקרא כשההודעה **חתומה נכון** אך נדחתה על הזמן, ומקבל
  /// את הפרש הזמן. זה המצב היחיד שבו אפשר לדעת בוודאות שההודעה הגיעה
  /// מהחברותא ובכל זאת נזרקה, ובלעדיו הוא בלתי ניתן לאבחון: השעון של אחד
  /// המחשבים סוטה ביותר מ-[freshnessWindow], והסנכרון פשוט שותק.
  static SyncMessage? decode(
    List<int> bytes,
    String normalizedRoomCode, {
    DateTime? now,
    void Function(Duration skew)? onClockSkew,
  }) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    if (raw['v'] != protocolVersion) return null;

    final typeWire = raw['t'];
    if (typeWire is! String) return null;
    final type = SyncMessageType.fromWire(typeWire);
    if (type == null) return null;

    final roomHash = raw['room'];
    final senderId = raw['src'];
    final senderName = raw['name'];
    final timestampMs = raw['ts'];
    final sequence = raw['seq'];
    final signature = raw['sig'];
    if (roomHash is! String ||
        senderId is! String ||
        senderName is! String ||
        timestampMs is! int ||
        sequence is! int ||
        signature is! String) {
      return null;
    }
    if (senderId.isEmpty || sequence < 0) return null;

    // סינון זול לפני ההצפנה: הודעה של חדר אחר נזרקת בלי לחשב HMAC.
    if (roomHash != hashRoomCode(normalizedRoomCode)) return null;

    final rawDesk = raw['desk'];

    final message = SyncMessage(
      type: type,
      roomHash: roomHash,
      senderId: senderId,
      senderName: senderName,
      timestampMs: timestampMs,
      sequence: sequence,
      location: SyncLocation.fromJson(raw['loc']),
      entries: DeskEntry.listFromJson(rawDesk),
    );

    if (!_constantTimeEquals(_sign(message._canonical(), normalizedRoomCode), signature)) {
      return null;
    }

    final reference = now ?? DateTime.now();
    final age = reference.millisecondsSinceEpoch - timestampMs;
    if (age.abs() > freshnessWindow.inMilliseconds) {
      // החתימה כבר אומתה, ולכן ההודעה ודאי מהחברותא — והדחייה היא פער
      // שעונים ולא רעש רשת. מדווחים החוצה כדי שאפשר יהיה לומר למשתמש מה
      // לתקן, במקום סנכרון שפשוט אינו קורה.
      onClockSkew?.call(Duration(milliseconds: age));
      return null;
    }

    // עדכון מיקום בלי מיקום תקין הוא הודעה שבורה. כך גם הודעת שולחן
    // בלי אף פריט תקין: היא אינה אומרת דבר, ורק הייתה מעירה את הממתינים.
    if (type == SyncMessageType.location && message.location == null) return null;
    if (type == SyncMessageType.desk && message.entries.isEmpty) return null;
    // הודעה גדולה מדי נזרקת ולא נחתכת. שולח תקין מפצל למנות של
    // [maxTabsPerMessage] (ראו [SyncHub]), ולכן רשימה ארוכה מזה אינה
    // באה מאיתנו; חיתוך שלה היה גם משנה את הבייטים שנחתמו.
    if (rawDesk is List && rawDesk.length > maxTabsPerMessage) return null;

    return message;
  }

  /// השוואה בזמן קבוע, כדי לא לדלוף מידע על החתימה דרך זמן התגובה.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
