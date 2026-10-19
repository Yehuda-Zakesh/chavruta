'use strict';

// כפילים לבדיקות של החיבור המרוחק: אוצריא (אחסון ו-fetchStream) ו-Web Locks.
//
// **הכפיל של Web Locks אינו ההוכחה שהנעילה עובדת** — זו נבדקה במנוע
// עצמו (Edge 155, ראו docs/remote-feasibility.md). הוא מממש את אותה
// סמנטיקה (הדרה, תור, steal שזורק AbortError אצל המחזיק, query), כדי
// לבדוק את הלוגיקה של התוסף מעליה.

/** "מחשב": אחסון תוסף אחד שכל המופעים שלו חולקים, ומנהל נעילות אחד. */
function machine() {
  return { storage: new Map(), locks: new LockManager() };
}

/**
 * `Otzaria.call` של מופע אחד. [fetchImpl] מבצע את הבקשה בפועל (ברירת
 * מחדל: `fetch` של Node), כדי שבדיקות יוכלו לדמות כשלים.
 */
function otzaria(host, options) {
  const opts = options || {};
  const calls = [];
  const fetchImpl = opts.fetch || fetch;
  function call(method, args) {
    calls.push(method);
    const a = args || {};
    switch (method) {
      case 'storage.get': {
        // הערך נקרא כשהקריאה מסתיימת, לא כשהתחילה — כמו קריאה אמיתית שמתעכבת.
        // `getHook(key)` יכול להחזיר הבטחה שמעכבת את הקריאה הזאת.
        const read = () => ({
          success: true,
          data: host.storage.has(a.key) ? JSON.parse(host.storage.get(a.key)) : null,
        });
        const held = opts.getHook ? opts.getHook(a.key) : null;
        return held ? held.then(read) : Promise.resolve(read());
      }
      case 'storage.set': {
        if (a.value === null || a.value === undefined) {
          return Promise.resolve({ success: false, error: { message: 'null' } });
        }
        // `setFail(key)` — כתיבה שנכשלת, כמו שאוצריא מחזירה (`success: false`).
        if (opts.setFail && opts.setFail(a.key)) {
          return Promise.resolve({ success: false, error: { code: 'error.internal', message: 'disk full' } });
        }
        // הערך נלכד עכשיו ונכתב כשהשער נפתח — כתיבה "שבדרך" אמיתית.
        const text = JSON.stringify(a.value);
        const apply = () => {
          host.storage.set(a.key, text);
          return { success: true, data: true };
        };
        if (opts.gate && opts.gate.closed) return opts.gate.opened.then(apply);
        return Promise.resolve(apply());
      }
      case 'storage.remove': {
        // `removeHook(key)` → `{ when: 'before' | 'after', wait }`: מעכב את
        // המחיקה עצמה, או רק את התשובה עליה (המפתח כבר נמחק באחסון).
        const remove = () => {
          host.storage.delete(a.key);
          return { success: true, data: true };
        };
        const held = opts.removeHook ? opts.removeHook(a.key) : null;
        if (!held) return Promise.resolve(remove());
        if (held.when === 'after') {
          const done = remove();
          return held.wait.then(() => done);
        }
        return held.wait.then(remove);
      }
      case 'storage.list':
        return Promise.resolve({ success: true, data: Array.from(host.storage.keys()) });
      case 'network.fetchStream':
        if (opts.denyNetwork) return failingStream(opts.denyNetwork);
        return fetchStream(fetchImpl, a);
      default:
        return Promise.resolve({ success: false, error: { message: 'unknown method ' + method } });
    }
  }
  call.calls = calls;
  return call;
}

/** שער לכתיבות אחסון של מופע אחד: `close()` מעכב, `open()` משחרר. */
function gate() {
  const g = { closed: false, opened: null };
  g.close = () => {
    g.closed = true;
    g.opened = new Promise((resolve) => (g._open = resolve));
  };
  g.open = () => {
    g.closed = false;
    if (g._open) g._open();
  };
  return g;
}

/** זרם שנכשל מיד, כמו שאוצריא מכשילה בקשה חסומה. */
function failingStream(message) {
  return {
    next: () => Promise.reject(new Error(message)),
    return: () => Promise.resolve({ done: true }),
    [Symbol.asyncIterator]() {
      return this;
    },
  };
}

/**
 * מדמה את `network.fetchStream`: פריט `response` ואחריו מקטעי `data`,
 * ו-`return()` שמבטל את הבקשה ומסיים המתנה פתוחה — בדיוק כמו
 * `createRpcStream` של אוצריא.
 */
function fetchStream(fetchImpl, args) {
  const controller = new AbortController();
  const queue = [];
  const waiters = [];
  let ended = false;
  let failure = null;
  const flush = () => {
    while (waiters.length && queue.length) waiters.shift().resolve({ value: queue.shift(), done: false });
    if (queue.length || !ended) return;
    while (waiters.length) {
      const w = waiters.shift();
      if (failure) w.reject(failure);
      else w.resolve({ value: undefined, done: true });
    }
  };
  const timer = setTimeout(() => controller.abort(new Error('Network stream timed out')), args.timeoutMs || 30000);
  (async () => {
    try {
      const res = await fetchImpl(args.url, {
        method: args.method || 'GET',
        headers: args.headers,
        body: args.body,
        signal: controller.signal,
      });
      queue.push({ type: 'response', status: res.status, ok: res.ok, headers: {} });
      flush();
      const text = await res.text();
      if (text) queue.push({ type: 'data', body: text });
    } catch (e) {
      if (!ended) failure = e instanceof Error ? e : new Error(String(e));
    } finally {
      clearTimeout(timer);
      ended = true;
      flush();
    }
  })();
  return {
    next() {
      if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
      if (ended) return failure ? Promise.reject(failure) : Promise.resolve({ value: undefined, done: true });
      return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
    },
    return() {
      if (!ended) {
        ended = true;
        controller.abort();
        flush();
      }
      return Promise.resolve({ value: undefined, done: true });
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  };
}

/** Web Locks במינימום הדרוש: בקשה בלעדית, תור, steal ו-query. */
class LockManager {
  constructor() {
    this.held = new Map(); // name -> { client, release, reject }
    this.pending = new Map(); // name -> [{ client, start }]
    /** כמה פעמים נלקחה נעילה ממחזיק חי (steal) — כדי להבחין במסירה מסודרת. */
    this.steals = 0;
  }

  /** נקרא כש"דף" מת: כל מה שהוא מחזיק משתחרר, והבקשות שלו נמחקות. */
  kill(client) {
    for (const [name, list] of this.pending) {
      this.pending.set(name, list.filter((p) => p.client !== client));
    }
    for (const [name, lock] of Array.from(this.held)) {
      if (lock.client === client) this._release(name);
    }
  }

  forClient(client) {
    const self = this;
    return {
      request(name, options, callback) {
        return self._request(client, name, options || {}, callback);
      },
      query() {
        return Promise.resolve({
          held: Array.from(self.held.keys()).map((name) => ({ name })),
          pending: Array.from(self.pending.entries()).flatMap(([name, l]) => l.map(() => ({ name }))),
        });
      },
    };
  }

  _request(client, name, options, callback) {
    return new Promise((resolve, reject) => {
      const start = () => {
        let settled = false;
        const lock = {
          client,
          reject: (e) => {
            if (settled) return;
            settled = true;
            reject(e);
          },
        };
        this.held.set(name, lock);
        Promise.resolve()
          .then(() => callback({ name }))
          .then(
            (v) => {
              if (this.held.get(name) === lock) this._release(name);
              if (!settled) {
                settled = true;
                resolve(v);
              }
            },
            (e) => {
              if (this.held.get(name) === lock) this._release(name);
              lock.reject(e);
            }
          );
      };
      if (options.steal) {
        const current = this.held.get(name);
        if (current) {
          this.steals++;
          this.held.delete(name);
          const err = new Error('stolen');
          err.name = 'AbortError';
          current.reject(err);
        }
        start();
        return;
      }
      if (!this.held.has(name)) start();
      else {
        const list = this.pending.get(name) || [];
        const entry = { client, start };
        list.push(entry);
        this.pending.set(name, list);
        // כמו ב-Web Locks: `signal` מבטל בקשה שעוד ממתינה בתור.
        if (options.signal) {
          options.signal.addEventListener('abort', () => {
            const queue = this.pending.get(name) || [];
            const at = queue.indexOf(entry);
            if (at < 0) return;
            queue.splice(at, 1);
            const err = new Error('aborted');
            err.name = 'AbortError';
            reject(err);
          });
        }
      }
    });
  }

  _release(name) {
    this.held.delete(name);
    const list = this.pending.get(name) || [];
    const next = list.shift();
    if (next) next.start();
  }
}

/** ממתין עד ש-[predicate] אמת, או נכשל אחרי [ms]. */
async function until(predicate, ms, label) {
  const deadline = Date.now() + (ms || 5000);
  for (;;) {
    const value = await predicate();
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timeout: ' + (label || 'condition'));
    await new Promise((r) => setTimeout(r, 25));
  }
}

module.exports = { machine, otzaria, LockManager, until, fetchStream, gate };
