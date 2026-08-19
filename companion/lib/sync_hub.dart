import 'dart:async';

import 'config.dart';
import 'lan_transport.dart';
import 'protocol.dart';

/// חלון הזמן שבו מיקום שזהה למיקום שהגיע מהחברותא נחשב "הד" ואינו משודר
/// בחזרה. בלעדיו שני מחשבים בסנכרון דו-כיווני היו דוחפים זה לזה את אותו
/// מיקום בלי סוף.
const Duration echoWindow = Duration(seconds: 6);

/// כל כמה זמן משדרים נוכחות, כדי שרשימת המחוברים תהיה עדכנית.
const Duration presenceInterval = Duration(seconds: 20);

/// מכשיר שלא נשמע ממנו כלום בפרק זמן זה נחשב מנותק.
const Duration peerTimeout = Duration(seconds: 70);

class PeerInfo {
  PeerInfo({required this.id, required this.name, required this.lastSeenMs});

  final String id;
  String name;
  int lastSeenMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'lastSeenMs': lastSeenMs,
  };
}

class RemoteUpdate {
  RemoteUpdate({
    required this.location,
    required this.fromId,
    required this.fromName,
    required this.timestampMs,
  });

  final SyncLocation location;
  final String fromId;
  final String fromName;
  final int timestampMs;

  Map<String, Object?> toJson() => {
    'location': location.toJson(),
    'fromId': fromId,
    'fromName': fromName,
    'timestampMs': timestampMs,
  };
}

/// הליבה: מחברת בין התוסף (דרך ה-API המקומי) לבין הרשת המקומית,
/// ומחזיקה את כל ההחלטות — מי חבר, מה המיקום המרוחק, ומה הד.
class SyncHub {
  SyncHub({required this.config, required this.transport, this.onLog}) {
    transport.inbound.listen(_handleInbound);
  }

  final CompanionConfig config;
  final LanTransport transport;
  final void Function(String message)? onLog;

  int _outgoingSequence = 0;

  final Map<String, PeerInfo> _peers = {};

  /// מונה שגדל בכל עדכון מרוחק חדש. התוסף מבקש `since=<seq>` וכך יודע
  /// אם יש משהו חדש בשבילו בלי לקבל את אותו עדכון פעמיים.
  int _remoteSequence = 0;
  RemoteUpdate? _remote;

  /// המיקום האחרון שהתוסף המקומי דיווח עליו.
  SyncLocation? _localLocation;

  /// המיקום המרוחק האחרון שנמסר לתוסף, וזמן המסירה — בסיס זיהוי ההד.
  SyncLocation? _lastHandedToPlugin;
  int _lastHandedToPluginAtMs = 0;

  /// המצב האחרון שנקלט מכל שולח, לזיהוי הודעות כפולות או מאוחרות.
  final Map<String, ({int sequence, int timestampMs})> _lastFromSender = {};

  final List<Completer<void>> _waiters = [];
  Timer? _presenceTimer;

  int get remoteSequence => _remoteSequence;

  Future<void> start() async {
    await transport.start();
    _presenceTimer = Timer.periodic(
      presenceInterval,
      (_) => _announcePresence(),
    );
    if (config.isPaired) await _announcePresence();
  }

  /// מחליף את קוד החברותא. יוצא מהחדר הקודם בהודעת פרידה, מנקה את מצב
  /// החדר הישן, ומודיע נוכחות בחדר החדש.
  Future<void> setRoom(String? rawCode) async {
    final normalized = rawCode == null || rawCode.trim().isEmpty
        ? null
        : CompanionConfig.normalizeRoomCode(rawCode);
    if (normalized == config.roomCode) return;

    if (config.isPaired) {
      await transport.send(_buildMessage(SyncMessageType.farewell));
    }

    config.roomCode = normalized;
    await config.save();

    // מצב של חדר אחד לא נשפך לחדר אחר.
    _peers.clear();
    _lastFromSender.clear();
    _remote = null;
    _lastHandedToPlugin = null;
    _remoteSequence++;
    _wakeWaiters();

    onLog?.call(normalized == null ? 'left the chavruta' : 'joined a chavruta');
    if (config.isPaired) await _announcePresence();
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == config.deviceName) return;
    config.deviceName = trimmed;
    await config.save();
    if (config.isPaired) await _announcePresence();
  }

  /// התוסף מדווח על מיקום הקריאה המקומי.
  ///
  /// מחזיר `true` אם המיקום שודר לחברותא, ו-`false` אם זוהה כהד של
  /// ניווט שהחברותא עצמה גרמה לו.
  Future<bool> publishLocal(SyncLocation location) async {
    _localLocation = location;
    if (!config.isPaired) return false;

    final handed = _lastHandedToPlugin;
    final sinceHanded =
        DateTime.now().millisecondsSinceEpoch - _lastHandedToPluginAtMs;
    if (handed != null &&
        location.sameSpotAs(handed) &&
        sinceHanded < echoWindow.inMilliseconds) {
      // זה ההד של הניווט שביצענו בעקבות החברותא — לא משדרים בחזרה.
      return false;
    }

    await transport.send(
      _buildMessage(SyncMessageType.location, location: location),
    );
    return true;
  }

  /// מסמן שהעדכון המרוחק נמסר לתוסף, כדי שההד שיחזור ממנו יזוהה.
  void markHandedToPlugin(SyncLocation location) {
    _lastHandedToPlugin = location;
    _lastHandedToPluginAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> _announcePresence() => transport.send(
    _buildMessage(SyncMessageType.presence, location: _localLocation),
  );

  SyncMessage _buildMessage(SyncMessageType type, {SyncLocation? location}) =>
      SyncMessage(
        type: type,
        roomHash: SyncMessage.hashRoomCode(config.roomCode ?? ''),
        senderId: config.deviceId,
        senderName: config.deviceName,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        sequence: ++_outgoingSequence,
        location: location,
      );

  void _handleInbound(SyncMessage message) {
    // הודעה שלנו שחזרה מהרשת: broadcast חוזר גם אל השולח.
    if (message.senderId == config.deviceId) return;

    if (message.type == SyncMessageType.farewell) {
      if (_peers.remove(message.senderId) != null) _wakeWaiters();
      return;
    }

    // הודעה כפולה או מאוחרת. השוואת חותמת הזמן מטפלת בחברותא שהופעלה
    // מחדש והמונה שלה חזר לאפס.
    final last = _lastFromSender[message.senderId];
    if (last != null &&
        message.sequence <= last.sequence &&
        message.timestampMs <= last.timestampMs) {
      return;
    }
    _lastFromSender[message.senderId] = (
      sequence: message.sequence,
      timestampMs: message.timestampMs,
    );

    final peer = _peers[message.senderId];
    if (peer == null) {
      _peers[message.senderId] = PeerInfo(
        id: message.senderId,
        name: message.senderName,
        lastSeenMs: message.timestampMs,
      );
      onLog?.call('peer joined: ${message.senderName}');
    } else {
      peer.name = message.senderName;
      peer.lastSeenMs = message.timestampMs;
    }

    final location = message.location;
    if (message.type == SyncMessageType.location && location != null) {
      // מיקום שאנחנו כבר נמצאים בו אינו עדכון — כך נמנעת התנגשות
      // כששני הצדדים הגיעו לאותו מקום.
      if (!location.sameSpotAs(_localLocation)) {
        _remote = RemoteUpdate(
          location: location,
          fromId: message.senderId,
          fromName: message.senderName,
          timestampMs: message.timestampMs,
        );
        _remoteSequence++;
      }
    }
    _wakeWaiters();
  }

  void _prunePeers() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - peerTimeout.inMilliseconds;
    _peers.removeWhere((_, peer) => peer.lastSeenMs < cutoff);
  }

  /// ממתין לשינוי במצב (עדכון מרוחק או שינוי ברשימת המחוברים), או עד
  /// שיפוג הזמן. כך התוסף מקבל דחיפה כמעט מיידית בלי לתחקר בלופ.
  Future<void> waitForChange(Duration timeout) {
    final completer = Completer<void>();
    _waiters.add(completer);
    Timer(timeout, () {
      if (_waiters.remove(completer) && !completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  void _wakeWaiters() {
    final pending = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  Map<String, Object?> snapshot() {
    _prunePeers();
    return {
      'deviceId': config.deviceId,
      'deviceName': config.deviceName,
      'paired': config.isPaired,
      'lanBound': transport.isBound,
      'remoteSequence': _remoteSequence,
      'remote': _remote?.toJson(),
      'localLocation': _localLocation?.toJson(),
      'peers': _peers.values.map((p) => p.toJson()).toList(),
    };
  }

  Future<void> dispose() async {
    _presenceTimer?.cancel();
    if (config.isPaired) {
      await transport.send(_buildMessage(SyncMessageType.farewell));
    }
    _wakeWaiters();
    await transport.dispose();
  }
}
