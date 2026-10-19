// מפיק וקטורי ייחוס של הפרוטוקול, כדי שהמימוש ב-JS שבתוסף (חיבור מרחוק)
// ייבדק מול המימוש הזה בדיוק — בייט לבייט.
//
//   dart run tool/protocol_vectors.dart > ../plugin-test/fixtures/protocol-vectors.json
//
// הקובץ שנוצר נשמר בריפו, ו-`test/protocol_vectors_test.dart` נכשל אם
// הפלט כאן השתנה בלי שהקובץ עודכן — כך שני המימושים אינם נפרדים בשקט.
import 'dart:convert';

import 'package:chavruta_companion/config.dart';
import 'package:chavruta_companion/protocol.dart';

/// קודים שמכסים כל ענף של [CompanionConfig.normalizeRoomCode].
const List<String> roomCodes = [
  'דף יומי',
  '  דף   יומי  ',
  '‏דף יומי‏',
  'דַּף יוֹמִי',
  'רש״י',
  'רש"י',
  '‘x’ “y”',
  'שׁבת',
  'שׁבת',
  'Daf YOMI',
  'מקף־עברי',
  'a­b​c﻿d',
  'emoji 😀 ok',
  // NEL בקצוות: `trim` של Dart מסיר אותו, ושל JS לא.
  '\x85קוד\x85',
];

List<SyncMessage> messages() => [
  const SyncMessage(
    type: SyncMessageType.location,
    roomHash: '',
    senderId: '0123456789abcdef',
    senderName: 'מחשב א',
    timestampMs: 1760000000000,
    sequence: 7,
    location: SyncLocation(bookId: 'ברכות', index: 42, ref: 'ברכות, דף ד.'),
  ),
  const SyncMessage(
    type: SyncMessageType.presence,
    roomHash: '',
    senderId: 'fedcba9876543210',
    // הלוכסן נכתב כ-`\x5c` ולא כ-`\\`: עורכים וכלי shell מכווצים `\\`.
    senderName: 'שם עם "מרכאות" ו' '\x5c' 'לוכסן\n',
    timestampMs: 1760000000001,
    sequence: 1,
  ),
  const SyncMessage(
    type: SyncMessageType.farewell,
    roomHash: '',
    senderId: 'fedcba9876543210',
    senderName: 'x\u0001\u001f\u007f 😀',
    timestampMs: 1760000000002,
    sequence: 2,
  ),
  const SyncMessage(
    type: SyncMessageType.desk,
    roomHash: '',
    senderId: '0123456789abcdef',
    senderName: 'מחשב א',
    timestampMs: 1760000000003,
    sequence: 3,
    entries: [
      DeskEntry(bookId: 'שולחן ערוך, אורח חיים', stamp: 1760000000003, by: '0123456789abcdef', index: 5),
      DeskEntry(bookId: 'שו״ת אגרות משה', stamp: 1760000000004, by: '0123456789abcdef', open: false),
    ],
  ),
  const SyncMessage(
    type: SyncMessageType.location,
    roomHash: '',
    senderId: '0123456789abcdef',
    senderName: 'מחשב א',
    timestampMs: 1760000000005,
    sequence: 8,
    location: SyncLocation(bookId: 'שבת', index: 0),
  ),
];

SyncMessage withRoom(SyncMessage m, String room) => SyncMessage(
  type: m.type,
  roomHash: room,
  senderId: m.senderId,
  senderName: m.senderName,
  timestampMs: m.timestampMs,
  sequence: m.sequence,
  location: m.location,
  entries: m.entries,
);

Map<String, Object?> vectors() {
  final normalized = [
    for (final raw in roomCodes)
      () {
        final code = CompanionConfig.normalizeRoomCode(raw);
        return {'raw': raw, 'normalized': code, 'roomHash': SyncMessage.hashRoomCode(code)};
      }(),
  ];
  const code = 'דף יומי';
  final room = SyncMessage.hashRoomCode(code);
  return {
    'normalize': normalized,
    'code': code,
    'messages': [
      for (final m in messages()) utf8.decode(withRoom(m, room).encode(code)),
    ],
  };
}

void main() {
  print(const JsonEncoder.withIndent('  ').convert(vectors()));
}
