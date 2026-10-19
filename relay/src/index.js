// שרת רילאי של חברותא: מעביר הודעות חתומות בין מחשבים שנמצאים באותו חדר.
//
// השרת **אינו מבין את ההודעות ואינו מאמת אותן**. החתימה (HMAC על קוד החדר)
// נבדקת אצל המקבל, ולכן שרת שנפרץ יכול לכל היותר להשמיט הודעות — לא לזייף.
//
//   POST /r/<roomHash>/send        גוף: הודעה אחת (JSON), עד MAX_BODY בייטים
//   GET  /r/<roomHash>/poll?since=N&wait=S
//        מחזיר {"next": N2, "messages": ["<json>", ...]}. אם אין הודעות חדשות
//        ממתין עד S שניות (עד MAX_WAIT_S) ואז מחזיר רשימה ריקה.

const ROOM_RE = /^[0-9a-f]{16}$/;
const MAX_BODY = 8 * 1024;

export { Room } from './room.js';

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json;charset=UTF-8', 'Cache-Control': 'no-store' },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/') return json({ ok: true, service: 'chavruta-relay' });

    const match = /^\/r\/([0-9a-f]{16})\/(send|poll)$/.exec(url.pathname);
    if (!match || !ROOM_RE.test(match[1])) return json({ error: 'not found' }, 404);
    const [, room, action] = match;

    if (action === 'send' && request.method !== 'POST') return json({ error: 'method' }, 405);
    if (action === 'poll' && request.method !== 'GET') return json({ error: 'method' }, 405);

    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    return stub.fetch(request);
  },
};
