import { DurableObject } from 'cloudflare:workers';

/** כמה הודעות אחרונות החדר זוכר, כדי שמי שמתחבר באיחור יקבל את המצב. */
const KEEP = 100;
const MAX_BODY = 8 * 1024;
const MAX_WAIT_S = 25;

/**
 * חדר אחד. ההודעות נשמרות בזיכרון בלבד: אם החדר נפלט, הלקוחות משדרים
 * מחדש את השולחן והנוכחות מעצמם (ראו `deskResyncInterval` במתאם).
 */
export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.seq = 0;
    this.log = []; // [{ n, body }]
    this.waiters = new Set();
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname.endsWith('/send')) return this.send(request);
    return this.poll(url);
  }

  async send(request) {
    const body = await request.text();
    if (body.length === 0 || body.length > MAX_BODY) {
      return new Response(JSON.stringify({ error: 'size' }), { status: 413 });
    }
    this.seq += 1;
    this.log.push({ n: this.seq, body });
    if (this.log.length > KEEP) this.log.splice(0, this.log.length - KEEP);
    for (const wake of this.waiters) wake();
    this.waiters.clear();
    return new Response(JSON.stringify({ next: this.seq }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  collect(since) {
    return this.log.filter((m) => m.n > since);
  }

  async poll(url) {
    // since=-1 (או חסר) = "אני חדש": מתחילים מההודעה הבאה ולא מהיסטוריה.
    const raw = Number.parseInt(url.searchParams.get('since') ?? '-1', 10);
    const since = Number.isFinite(raw) && raw >= 0 ? raw : this.seq;
    const wait = Math.min(
      Math.max(Number.parseInt(url.searchParams.get('wait') ?? '0', 10) || 0, 0),
      MAX_WAIT_S,
    );

    let found = this.collect(since);
    if (found.length === 0 && wait > 0) {
      await new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.waiters.delete(done);
          resolve();
        }, wait * 1000);
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        this.waiters.add(done);
      });
      found = this.collect(since);
    }

    return new Response(
      JSON.stringify({ next: this.seq, messages: found.map((m) => m.body) }),
      { headers: { 'Content-Type': 'application/json;charset=UTF-8', 'Cache-Control': 'no-store' } },
    );
  }
}
