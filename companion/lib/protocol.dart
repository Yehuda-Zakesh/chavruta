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

enum SyncMessageType {
  /// עדכון מיקום קריאה.
  location,

  /// נוכחות: "אני כאן", לרשימת המחוברים. אינו משנה מיקום.
  presence,

  /// יציאה מסודרת מהחברותא.
  farewell;

  String get wire => switch (this) {
    SyncMessageType.location => 'loc',
    SyncMessageType.presence => 'hi',
    SyncMessageType.farewell => 'bye',
  };

  static SyncMessageType? fromWire(String value) => switch (value) {
    'loc' => SyncMessageType.location,
    'hi' => SyncMessageType.presence,
    'bye' => SyncMessageType.farewell,
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
  });

  final SyncMessageType type;
  final String roomHash;
  final String senderId;
  final String senderName;
  final int timestampMs;
  final int sequence;
  final SyncLocation? location;

  /// גיבוב קוד החברותא — 16 תווים הקסה. מזהה את החדר בלי לחשוף את הקוד.
  static String hashRoomCode(String normalizedRoomCode) =>
      sha256.convert(utf8.encode('chavruta-room:$normalizedRoomCode')).toString().substring(0, 16);

  /// הצורה הקנונית שעליה נחתמת החתימה. סדר המפתחות קבוע בקוד, ולכן
  /// שני צדדים שמריצים את אותו קוד מייצרים בדיוק את אותם בייטים.
  Map<String, Object?> _canonical() => {
    'v': protocolVersion,
    't': type.wire,
    'room': roomHash,
    'src': senderId,
    'name': senderName,
    'ts': timestampMs,
    'seq': sequence,
    'loc': location?.toJson(),
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

    final message = SyncMessage(
      type: type,
      roomHash: roomHash,
      senderId: senderId,
      senderName: senderName,
      timestampMs: timestampMs,
      sequence: sequence,
      location: SyncLocation.fromJson(raw['loc']),
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

    // עדכון מיקום בלי מיקום תקין הוא הודעה שבורה.
    if (type == SyncMessageType.location && message.location == null) return null;

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
