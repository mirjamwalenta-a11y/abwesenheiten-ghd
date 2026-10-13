// ============================================================
// GHD-OFFLINE — Service-Worker-Teil, gemeinsam für alle Great-Hair-Day-Apps
//
// Jede App hat eine kleine eigene sw.js, die nur ihre Einstellungen setzt
// und diese Datei lädt:
//
//   self.GHD_OFFLINE = { app: 'lager', version: '2026-10-13', vorab: ['./', './Lager_index.html'] };
//   importScripts('https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-offline-sw.js');
//
// Was hier passiert:
//  1. App-Dateien (HTML, Skripte, Bilder, Schriften) werden im Handy
//     gespeichert → die App startet auch ohne Netz.
//  2. Supabase-Daten (GET /rest/v1/<tabelle>) werden nach jedem Laden im
//     Handy gemerkt (IndexedDB, getrennt pro angemeldeter Person) und ohne
//     Netz von dort geliefert.
//  3. Speichern ohne Netz (POST/PATCH/DELETE auf /rest/v1/<tabelle> und
//     Datei-Uploads in Supabase Storage) landet in einer Warteschlange im
//     Handy und wird automatisch nachgeschickt, sobald wieder Netz da ist.
//
// Konfliktregel (festgelegt 2026-10-13): NICHTS ÜBERSCHREIBEN.
//  - Neue Einträge (POST) und Uploads werden immer nachgeschickt.
//  - Änderungen/Löschungen (PATCH/DELETE) werden nur nachgeschickt, wenn
//    der Eintrag am Server noch genau so aussieht wie zu dem Zeitpunkt, als
//    er zuletzt geladen wurde. Hat ihn inzwischen jemand anderer geändert,
//    wird NICHT überschrieben, sondern die Änderung als Konflikt angezeigt
//    (ghd-offline.js), und die Person entscheidet selbst.
//
// Bewusst NIE zwischengespeichert oder nachgeschickt:
//  - Anmeldung (/auth/v1), Edge Functions (/functions/v1), RPC-Funktionen
//    (/rest/v1/rpc/…). RPCs prüfen serverseitig Rechte, Zeit oder Ort
//    (z. B. Stempeln nur im Salon-Netz) — ein späteres Nachschicken würde
//    diese Prüfungen verfälschen. Sie brauchen weiterhin Netz.
// ============================================================
(function () {
  'use strict';
  var CFG = self.GHD_OFFLINE || {};
  var APP = String(CFG.app || 'app');
  var CACHE_PREFIX = 'ghd-' + APP + '-';            // alle Apps teilen sich den Speicher (gleiche Adresse) → eigenes Präfix
  var CACHE = CACHE_PREFIX + (CFG.version || '1');
  var DB_NAME = 'ghd-offline-' + APP;
  var SB_HOST = 'wrxlaltgtgkdomklgrlj.supabase.co';
  var GEMEINSAM = 'https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/';
  var START = CFG.start || './';
  var VORAB = (CFG.vorab || []).concat([
    GEMEINSAM + 'ghd-sitzung.js',
    GEMEINSAM + 'ghd-offline.js'
  ]);
  // Fremde Adressen, deren Dateien (Bibliotheken, Schriften) gespeichert werden dürfen
  var FREMD_ERLAUBT = ['fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'unpkg.com', 'cdn.tailwindcss.com'];
  var RESERVIERT = { select: 1, order: 1, limit: 1, offset: 1, on_conflict: 1, columns: 1 };

  // ---------- Installation / Aufräumen ----------
  self.addEventListener('install', function (event) {
    event.waitUntil((async function () {
      var cache = await caches.open(CACHE);
      await Promise.all(VORAB.map(async function (url) {
        try {
          var res = await fetch(url, { cache: 'reload' });
          if (res.ok || res.type === 'opaque') await cache.put(url, res);
        } catch (e) { /* einzelne fehlende Datei bricht die Installation nicht ab */ }
      }));
      await self.skipWaiting();
    })());
  });

  self.addEventListener('activate', function (event) {
    event.waitUntil((async function () {
      var namen = await caches.keys();
      await Promise.all(namen.filter(function (n) { return n.indexOf(CACHE_PREFIX) === 0 && n !== CACHE; })
        .map(function (n) { return caches.delete(n); }));
      await self.clients.claim();
    })());
  });

  // ---------- Hilfen ----------
  function mitTimeout(promise, ms) {
    return Promise.race([promise, new Promise(function (_, nein) { setTimeout(function () { nein(new Error('timeout')); }, ms); })]);
  }
  function jsonAntwort(status, obj, extra) {
    var h = { 'Content-Type': 'application/json; charset=utf-8', 'x-ghd-offline': '1' };
    for (var k in (extra || {})) h[k] = extra[k];
    return new Response(obj === null ? null : JSON.stringify(obj), { status: status, headers: h });
  }
  function base64urlJson(teil) {
    var s = teil.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    return JSON.parse(decodeURIComponent(Array.prototype.map.call(atob(s), function (c) {
      return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
    }).join('')));
  }
  function jwtNutzlast(token) {
    if (!token) return null;
    var t = String(token).replace(/^Bearer\s+/i, '').split('.');
    if (t.length !== 3) return null;
    try { return base64urlJson(t[1]); } catch (e) { return null; }
  }
  async function sha256(text) {
    var buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
    return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('').slice(0, 32);
  }
  // Wer fragt? Bei Supabase-Anmeldung die Personen-ID (bleibt nach Token-
  // Erneuerung gleich), sonst ein Fingerabdruck aller Anmelde-Header.
  // Gespeicherte Daten sind so streng pro Person getrennt.
  async function identitaet(headers) {
    var p = jwtNutzlast(headers.get('authorization'));
    if (p && p.sub) return 'u:' + p.sub;
    var s = headers.get('authorization') || '';
    headers.forEach(function (v, k) { if (k.indexOf('x-') === 0 && k !== 'x-client-info') s += '|' + k + '=' + v; });
    return 'h:' + await sha256(s);
  }

  // ---------- IndexedDB ----------
  var dbPromise = null;
  function db() {
    if (!dbPromise) dbPromise = new Promise(function (ok, nein) {
      var r = indexedDB.open(DB_NAME, 1);
      r.onupgradeneeded = function () {
        var d = r.result;
        d.createObjectStore('antworten');
        d.createObjectStore('warteschlange', { keyPath: 'nr', autoIncrement: true });
        d.createObjectStore('konflikte', { keyPath: 'nr', autoIncrement: true });
        d.createObjectStore('tokens');
      };
      r.onsuccess = function () { ok(r.result); };
      r.onerror = function () { dbPromise = null; nein(r.error); };
    });
    return dbPromise;
  }
  async function idb(store, modus, fn) {
    var d = await db();
    return new Promise(function (ok, nein) {
      var tx = d.transaction(store, modus);
      var ergebnis;
      var r = fn(tx.objectStore(store));
      if (r) r.onsuccess = function () { ergebnis = r.result; };
      tx.oncomplete = function () { ok(ergebnis); };
      tx.onerror = tx.onabort = function () { nein(tx.error); };
    });
  }
  function idbGet(store, key) { return idb(store, 'readonly', function (s) { return s.get(key); }); }
  function idbAlle(store) { return idb(store, 'readonly', function (s) { return s.getAll(); }); }
  function idbAlleSchluessel(store) { return idb(store, 'readonly', function (s) { return s.getAllKeys(); }); }
  function idbPut(store, wert, key) { return idb(store, 'readwrite', function (s) { return key === undefined ? s.put(wert) : s.put(wert, key); }); }
  function idbDel(store, key) { return idb(store, 'readwrite', function (s) { return s.delete(key); }); }
  function idbLeeren(store) { return idb(store, 'readwrite', function (s) { return s.clear(); }); }

  // ---------- PostgREST-Filter ----------
  function tabelleVon(url) {
    var m = /^\/rest\/v1\/([^/?]+)$/.exec(url.pathname);
    return m ? decodeURIComponent(m[1]) : null;
  }
  function filterVon(url) {
    var f = [];
    url.searchParams.forEach(function (wert, spalte) { if (!RESERVIERT[spalte]) f.push([spalte, wert]); });
    f.sort(function (a, b) { return (a[0] + a[1]) < (b[0] + b[1]) ? -1 : 1; });
    return f;
  }
  function filterText(f) { return f.map(function (x) { return x[0] + '=' + x[1]; }).join('&'); }
  // true / false / null (= nicht auswertbar)
  function passt(zeile, spalte, ausdruck) {
    if (spalte === 'or' || spalte === 'and' || spalte === 'not') return null;
    if (!zeile || !Object.prototype.hasOwnProperty.call(zeile, spalte)) return null;
    var m = /^(not\.)?([a-z]+)\.(.*)$/.exec(ausdruck);
    if (!m) return null;
    var nicht = !!m[1], op = m[2], w = m[3], v = zeile[spalte];
    var s = v === null || v === undefined ? null : (typeof v === 'object' ? JSON.stringify(v) : String(v));
    var r;
    if (op === 'eq') r = s === w;
    else if (op === 'neq') r = s !== w;
    else if (op === 'is') r = w === 'null' ? v === null : (w === 'true' ? v === true : (w === 'false' ? v === false : null));
    else if (op === 'in') {
      var liste = w.replace(/^\(|\)$/g, '').split(',').map(function (x) { return x.replace(/^"|"$/g, ''); });
      r = s !== null && liste.indexOf(s) >= 0;
    } else if (op === 'gt' || op === 'gte' || op === 'lt' || op === 'lte') {
      if (s === null) r = false;
      else {
        var a = Number(s), b = Number(w), num = !isNaN(a) && !isNaN(b) && s !== '' && w !== '';
        var c = num ? (a < b ? -1 : a > b ? 1 : 0) : (s < w ? -1 : s > w ? 1 : 0);
        r = op === 'gt' ? c > 0 : op === 'gte' ? c >= 0 : op === 'lt' ? c < 0 : c <= 0;
      }
    } else return null;
    if (r === null) return null;
    return nicht ? !r : r;
  }
  // Passt die Zeile auf alle Filter? Filter, die schon in der Abfrage der
  // gespeicherten Antwort standen, gelten für jede Zeile darin als erfüllt.
  function zeilePasst(zeile, filter, filterDerAbfrage) {
    for (var i = 0; i < filter.length; i++) {
      var f = filter[i];
      var schon = filterDerAbfrage && filterDerAbfrage.some(function (g) { return g[0] === f[0] && g[1] === f[1]; });
      if (schon) continue;
      if (passt(zeile, f[0], f[1]) !== true) return false;
    }
    return true;
  }
  function schluesselVon(zeile) {
    return zeile && zeile.id !== undefined ? 'id:' + JSON.stringify(zeile.id) : null;
  }

  // ---------- Statische Dateien ----------
  async function netzZuerst(req, ms, fallbackStart) {
    var cache = await caches.open(CACHE);
    var netz = fetch(req).then(function (res) {
      if (res.ok) cache.put(req, res.clone());
      return res;
    });
    try {
      return await mitTimeout(netz, ms);
    } catch (e) {
      var treffer = await cache.match(req, { ignoreSearch: req.mode === 'navigate' }) || await cache.match(req, { ignoreSearch: true });
      if (treffer) return treffer;
      try { return await netz; } catch (e2) {
        if (fallbackStart) { var s = await cache.match(START); if (s) return s; }
        return Response.error();
      }
    }
  }
  async function speicherZuerst(req, event) {
    var cache = await caches.open(CACHE);
    var treffer = await cache.match(req);
    var netz = fetch(req).then(function (res) {
      if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
      return res;
    }).catch(function () { return null; });
    if (treffer) { event.waitUntil(netz); return treffer; }
    return (await netz) || Response.error();
  }

  // ---------- Supabase: Lesen ----------
  async function datenLesen(req) {
    var url = new URL(req.url);
    var ident = await identitaet(req.headers);
    var key = ident + '|' + (req.headers.get('accept') || '') + '|' + req.url;
    var res = null;
    try {
      res = await mitTimeout(fetch(req.clone()), CFG.datenTimeout || 8000);
    } catch (e) { res = null; }
    if (res && res.ok) {
      var text = await res.clone().text();
      try {
        await idbPut('antworten', { text: text, status: res.status, typ: res.headers.get('content-type'), bereich: res.headers.get('content-range'), zeit: Date.now(), url: req.url, ident: ident }, key);
      } catch (e) { /* Speicher voll o. ä. – App funktioniert trotzdem */ }
      var offen = await wartendFuer(ident, tabelleVon(url));
      if (offen.length) {
        synchronisieren();
        return new Response(ueberlagern(text, url, offen), { status: res.status, headers: res.headers });
      }
      return res;
    }
    if (res) return res; // Server hat geantwortet (z. B. 401) → unverändert weiterreichen
    var g = await idbGet('antworten', key).catch(function () { return null; });
    if (!g) return jsonAntwort(503, { message: 'Offline – diese Daten wurden auf diesem Gerät noch nicht geladen.', code: 'GHD_OFFLINE' });
    var h = { 'Content-Type': g.typ || 'application/json', 'x-ghd-offline': '1' };
    if (g.bereich) h['Content-Range'] = g.bereich;
    return new Response(ueberlagern(g.text, url, await wartendFuer(ident, tabelleVon(url))), { status: g.status, headers: h });
  }
  async function wartendFuer(ident, tabelle) {
    if (!tabelle) return [];
    var alle = await idbAlle('warteschlange').catch(function () { return []; });
    return alle.filter(function (w) { return w.ident === ident && w.tabelle === tabelle; }).sort(function (a, b) { return a.nr - b.nr; });
  }
  // Eigene, noch nicht hochgeladene Änderungen in gelesene Daten einrechnen,
  // damit die App nach dem Neuladen zeigt, was eingegeben wurde.
  function ueberlagern(text, url, offen) {
    if (!offen.length) return text;
    var daten;
    try { daten = JSON.parse(text); } catch (e) { return text; }
    var einzeln = !Array.isArray(daten);
    var zeilen = einzeln ? [daten] : daten;
    var abfrageFilter = filterVon(url);
    offen.forEach(function (w) {
      if (w.art === 'aendern' || w.art === 'upsert') {
        var getroffen = false;
        zeilen = zeilen.map(function (z) { if (zeilePasst(z, w.filter, abfrageFilter)) { getroffen = true; return Object.assign({}, z, w.koerperJson); } return z; });
        if (w.art === 'upsert' && !getroffen && !einzeln && zeilePasst(w.koerperJson, abfrageFilter, null)) zeilen = zeilen.concat([w.koerperJson]);
      } else if (w.art === 'loeschen') {
        zeilen = zeilen.filter(function (z) { return !zeilePasst(z, w.filter, abfrageFilter); });
      } else if (w.art === 'neu' && !einzeln && w.koerperJson) {
        // neue Zeilen nur dort zeigen, wo sie zur Abfrage passen
        zeilen = zeilen.concat((Array.isArray(w.koerperJson) ? w.koerperJson : [w.koerperJson]).filter(function (z) { return zeilePasst(z, abfrageFilter, null); }));
      }
    });
    if (einzeln) return zeilen.length ? JSON.stringify(zeilen[0]) : text;
    return JSON.stringify(zeilen);
  }

  // Wie sah der Eintrag aus, als er zuletzt vom Server geladen wurde?
  async function stand(ident, tabelle, filter) {
    var alle = await idbAlle('antworten').catch(function () { return []; });
    var gefunden = {}, zeiten = {}, ohneSchluessel = null, ohneZeit = 0;
    alle.forEach(function (a) {
      if (a.ident !== ident) return;
      var u = new URL(a.url);
      if (tabelleVon(u) !== tabelle) return;
      var daten;
      try { daten = JSON.parse(a.text); } catch (e) { return; }
      var zeilen = Array.isArray(daten) ? daten : [daten];
      var af = filterVon(u);
      var treffer = zeilen.filter(function (z) { return z && typeof z === 'object' && zeilePasst(z, filter, af); });
      treffer.forEach(function (z) {
        var k = schluesselVon(z);
        if (k === null) {
          if (a.zeit >= ohneZeit) { ohneZeit = a.zeit; ohneSchluessel = treffer; }
          return;
        }
        if (!zeiten[k] || a.zeit >= zeiten[k]) { zeiten[k] = a.zeit; gefunden[k] = z; }
      });
    });
    var liste = Object.keys(gefunden).map(function (k) { return gefunden[k]; });
    if (liste.length) return liste;
    return ohneSchluessel; // null = unbekannt
  }

  // ---------- Supabase: Schreiben ----------
  async function datenSchreiben(req, art, event) {
    var kopie = req.clone();
    var fuerCache = art === 'datei' ? null : req.clone();
    if (CFG.vorherSync !== false) {
      try { await mitTimeout(synchronisieren(), 15000); } catch (e) { /* weiter */ }
    }
    var res;
    try {
      res = await fetch(req);
    } catch (e) {
      return einreihen(kopie, art);
    }
    if (res.ok && fuerCache) event.waitUntil(nachSchreiben(fuerCache).catch(function () {}));
    return res;
  }
  // Nach erfolgreichem Speichern den gemerkten Stand sofort anpassen und im
  // Hintergrund neu laden – sonst würde eine spätere Offline-Änderung mit
  // einem veralteten Stand verglichen und fälschlich als Konflikt gelten.
  async function nachSchreiben(req) {
    var url = new URL(req.url), tabelle = tabelleVon(url);
    if (!tabelle) return;
    var ident = await identitaet(req.headers);
    var filter = filterVon(url);
    var koerper = null;
    try { koerper = JSON.parse(await req.text()); } catch (e) { koerper = null; }
    var alle = await idbAlle('antworten').catch(function () { return []; });
    var schluessel = await idbAlleSchluessel('antworten').catch(function () { return []; });
    var nachladen = [];
    for (var i = 0; i < alle.length; i++) {
      var a = alle[i];
      if (a.ident !== ident) continue;
      var au = new URL(a.url);
      if (tabelleVon(au) !== tabelle) continue;
      nachladen.push({ key: schluessel[i], a: a });
      if (req.method === 'PATCH' && koerper && !Array.isArray(koerper)) {
        try {
          var daten = JSON.parse(a.text), af = filterVon(au), einzeln = !Array.isArray(daten);
          var zeilen = (einzeln ? [daten] : daten).map(function (z) { return zeilePasst(z, filter, af) ? Object.assign({}, z, koerper) : z; });
          a.text = JSON.stringify(einzeln ? zeilen[0] : zeilen);
          await idbPut('antworten', a, schluessel[i]);
        } catch (e) { /* egal */ }
      }
    }
    var h = { apikey: req.headers.get('apikey') || '', authorization: req.headers.get('authorization') || '' };
    await Promise.all(nachladen.slice(0, 20).map(async function (n) {
      try {
        var accept = n.key.split('|')[1] || 'application/json';
        var r = await mitTimeout(fetch(n.a.url, { headers: Object.assign({ accept: accept }, h) }), 10000);
        if (!r.ok) return;
        n.a.text = await r.text(); n.a.zeit = Date.now();
        n.a.bereich = r.headers.get('content-range');
        await idbPut('antworten', n.a, n.key);
      } catch (e) { /* offline – egal */ }
    }));
  }
  async function einreihen(req, art) {
    var url = new URL(req.url);
    var istDatei = art === 'datei';
    var koerper = istDatei ? await req.arrayBuffer() : await req.text();
    var koerperJson = null;
    if (!istDatei && koerper) { try { koerperJson = JSON.parse(koerper); } catch (e) { koerperJson = null; } }
    var headers = {};
    req.headers.forEach(function (v, k) { headers[k] = v; });
    var ident = await identitaet(req.headers);
    var tabelle = istDatei ? null : tabelleVon(url);
    var filter = filterVon(url);
    // „Anlegen oder überschreiben“ (Upsert): betroffenen Eintrag über die
    // Konflikt-Spalten bestimmen, damit auch hier nichts überschrieben wird
    if (art === 'neu' && /resolution=merge-duplicates/.test(req.headers.get('prefer') || '')) {
      var zeile = Array.isArray(koerperJson) ? (koerperJson.length === 1 ? koerperJson[0] : null) : koerperJson;
      var spalten = url.searchParams.get('on_conflict') ? url.searchParams.get('on_conflict').split(',') : (zeile && zeile.id !== undefined ? ['id'] : null);
      if (zeile && spalten && spalten.every(function (sp) { return zeile[sp] !== undefined && zeile[sp] !== null; })) {
        art = 'upsert';
        koerperJson = zeile;
        filter = spalten.map(function (sp) { return [sp, 'eq.' + (typeof zeile[sp] === 'object' ? JSON.stringify(zeile[sp]) : String(zeile[sp]))]; })
          .sort(function (a, b) { return (a[0] + a[1]) < (b[0] + b[1]) ? -1 : 1; });
      }
    }
    var eintrag = {
      zeit: Date.now(), ident: ident, art: art, methode: req.method, url: req.url, headers: headers,
      koerper: koerper, koerperJson: koerperJson, tabelle: tabelle, filter: filter, stand: null
    };
    var offen = await wartendFuer(ident, tabelle);
    var gleich = offen.filter(function (w) { return w.art !== 'neu' && filterText(w.filter) === filterText(filter); }).pop();
    if (art === 'upsert' && gleich && gleich.art === 'upsert') {
      gleich.koerperJson = Object.assign({}, gleich.koerperJson, koerperJson);
      gleich.koerper = JSON.stringify(gleich.koerperJson);
      gleich.headers = headers;
      await idbPut('warteschlange', gleich);
      eintrag = gleich;
    } else if ((art === 'aendern' || art === 'loeschen') && gleich) {
      // Mehrere Offline-Änderungen am selben Eintrag → zusammenfassen, Stand vom Server bleibt der ursprüngliche
      if (art === 'aendern' && gleich.art === 'aendern') {
        gleich.koerperJson = Object.assign({}, gleich.koerperJson, koerperJson);
        gleich.koerper = JSON.stringify(gleich.koerperJson);
      } else {
        gleich.art = art; gleich.methode = req.method; gleich.url = req.url;
        gleich.koerper = koerper; gleich.koerperJson = koerperJson;
      }
      gleich.headers = headers;
      await idbPut('warteschlange', gleich);
      eintrag = gleich;
    } else {
      eintrag.art = art; eintrag.filter = filter; eintrag.koerperJson = koerperJson;
      if (art === 'aendern' || art === 'loeschen' || art === 'upsert') eintrag.stand = await stand(ident, tabelle, filter);
      eintrag.nr = await idbPut('warteschlange', eintrag);
    }
    try { if (self.registration.sync) await self.registration.sync.register('ghd-offline-sync'); } catch (e) { /* nicht überall verfügbar (iPhone) */ }
    statusMelden();
    return ersatzAntwort(req, eintrag);
  }
  // Antwort, als hätte der Server gespeichert – damit die App normal weiterläuft
  function ersatzAntwort(req, w) {
    if (w.art === 'datei') {
      var pfad = new URL(w.url).pathname.replace(/^\/storage\/v1\/object\//, '');
      return jsonAntwort(200, { Key: pfad, Id: 'offline-' + w.nr });
    }
    var prefer = req.headers.get('prefer') || '';
    var mitDaten = /return=representation/.test(prefer);
    var einzeln = /vnd\.pgrst\.object/.test(req.headers.get('accept') || '');
    var zeilen;
    if (w.art === 'neu') zeilen = Array.isArray(w.koerperJson) ? w.koerperJson : (w.koerperJson ? [w.koerperJson] : []);
    else if (w.art === 'upsert') zeilen = [Object.assign({}, (w.stand && w.stand[0]) || {}, w.koerperJson)];
    else if (w.art === 'aendern') zeilen = (w.stand && w.stand.length ? w.stand : [{}]).map(function (z) { return Object.assign({}, z, w.koerperJson); });
    else zeilen = w.stand || [];
    var status = (w.art === 'neu' || w.art === 'upsert') ? 201 : (mitDaten ? 200 : 204);
    if (!mitDaten) return new Response(null, { status: status, headers: { 'x-ghd-offline': 'wartet' } });
    return jsonAntwort(status, einzeln ? (zeilen[0] || null) : zeilen, { 'x-ghd-offline': 'wartet' });
  }

  // ---------- Anmelde-Token für das Nachschicken ----------
  var tokens = {};
  async function tokenMerken(token) {
    var p = jwtNutzlast(token);
    if (!p || !p.sub || !p.exp) return;
    var k = 'u:' + p.sub;
    var alt = tokens[k] || await idbGet('tokens', k).catch(function () { return null; });
    if (!alt || alt.exp < p.exp) {
      tokens[k] = { token: token, exp: p.exp };
      try { await idbPut('tokens', tokens[k], k); } catch (e) { /* egal */ }
    }
  }
  async function frischerToken(ident) {
    var t = tokens[ident] || await idbGet('tokens', ident).catch(function () { return null; });
    if (t && t.exp * 1000 > Date.now() + 60000) return t.token;
    return null;
  }

  // ---------- Nachschicken ----------
  var laeuft = null;
  function synchronisieren() {
    if (!laeuft) laeuft = syncIntern().catch(function () {}).then(function () { laeuft = null; statusMelden(); });
    return laeuft;
  }
  async function syncIntern() {
    var liste = (await idbAlle('warteschlange')).sort(function (a, b) { return a.nr - b.nr; });
    var blockiert = {};
    for (var i = 0; i < liste.length; i++) {
      var w = liste[i];
      if (blockiert[w.ident]) continue;      // Reihenfolge pro Person einhalten
      var r = await einspielen(w);
      if (r === 'warten') blockiert[w.ident] = true;
    }
  }
  function vergleichen(stand, aktuell, w) {
    var spalten = {};
    stand.forEach(function (z) { Object.keys(z).forEach(function (k) { spalten[k] = 1; }); });
    function proj(z) { var o = {}; Object.keys(spalten).forEach(function (k) { o[k] = z ? z[k] : undefined; }); return JSON.stringify(o); }
    if (w.art === 'loeschen' && aktuell.length === 0) return 'schon';
    if ((w.art === 'aendern' || w.art === 'upsert') && aktuell.length && w.koerperJson && aktuell.every(function (z) {
      return Object.keys(w.koerperJson).every(function (k) { return JSON.stringify(z[k]) === JSON.stringify(w.koerperJson[k]); });
    })) return 'schon';
    if (aktuell.length !== stand.length) return 'anders';
    var a = aktuell.map(proj).sort(), s = stand.map(proj).sort();
    for (var i = 0; i < a.length; i++) if (a[i] !== s[i]) return 'anders';
    return 'gleich';
  }
  async function einspielen(w) {
    var headers = new Headers(w.headers);
    if (w.ident.indexOf('u:') === 0) {
      var t = await frischerToken(w.ident);
      if (!t) return 'warten';                 // erst wieder mit gültiger Anmeldung derselben Person
      headers.set('authorization', 'Bearer ' + t);
    }
    if ((w.art === 'aendern' || w.art === 'loeschen' || w.art === 'upsert') && !w.trotzdem) {
      if (!w.stand && w.art !== 'upsert') return konflikt(w, null, 'Der Eintrag war auf diesem Gerät nicht geladen – ob ihn inzwischen jemand anderer geändert hat, lässt sich nicht prüfen.');
      var pu = new URL(w.url);
      pu.search = '';
      w.filter.forEach(function (f) { pu.searchParams.append(f[0], f[1]); });
      pu.searchParams.set('select', '*');
      var pruef;
      try {
        pruef = await fetch(pu.toString(), { headers: { apikey: headers.get('apikey') || '', authorization: headers.get('authorization') || '', accept: 'application/json' } });
      } catch (e) { return 'warten'; }
      if (pruef.status === 401) return 'warten';
      if (!pruef.ok) return 'warten';
      var aktuell = await pruef.json();
      var v = vergleichen(w.stand || [], Array.isArray(aktuell) ? aktuell : [aktuell], w);
      if (v === 'schon') { await idbDel('warteschlange', w.nr); return 'ok'; }
      if (v === 'anders') return konflikt(w, aktuell, w.stand && w.stand.length
        ? 'Jemand anderer hat diesen Eintrag inzwischen geändert. Deine Offline-Änderung wurde deshalb nicht gespeichert.'
        : 'Diesen Eintrag hat inzwischen jemand anderer angelegt. Deine Offline-Eingabe wurde deshalb nicht gespeichert.');
    }
    var res;
    try {
      res = await fetch(w.url, { method: w.methode, headers: headers, body: w.koerper === '' ? undefined : w.koerper });
    } catch (e) { return 'warten'; }
    if (res.ok) {
      await idbDel('warteschlange', w.nr);
      if (w.art !== 'datei') {
        try { await nachSchreiben(new Request(w.url, { method: w.methode, headers: headers, body: w.koerper === '' ? undefined : w.koerper })); } catch (e) { /* egal */ }
      }
      return 'ok';
    }
    if (res.status === 401 || res.status === 408 || res.status === 429 || res.status >= 500) return 'warten';
    var text = '';
    try { text = (await res.text()).slice(0, 300); } catch (e) { /* egal */ }
    return konflikt(w, null, 'Der Server hat die Änderung abgelehnt (HTTP ' + res.status + (text ? ': ' + text : '') + ').');
  }
  async function konflikt(w, server, grund) {
    var k = {
      zeit: Date.now(), app: APP, ident: w.ident, tabelle: w.tabelle, art: w.art, filter: filterText(w.filter || []),
      meine: w.art === 'datei' ? '[Datei]' : w.koerperJson, vorher: w.stand, server: server, grund: grund, eintrag: w
    };
    await idbPut('konflikte', k);
    await idbDel('warteschlange', w.nr);
    return 'konflikt';
  }

  // ---------- Status an die geöffneten Seiten ----------
  async function status() {
    var w = await idbAlleSchluessel('warteschlange').catch(function () { return []; });
    var k = await idbAlle('konflikte').catch(function () { return []; });
    return { typ: 'ghd-offline-status', wartend: w.length, konflikte: k.map(function (x) {
      return { nr: x.nr, zeit: x.zeit, tabelle: x.tabelle, art: x.art, filter: x.filter, meine: x.meine, vorher: x.vorher, server: x.server, grund: x.grund };
    }) };
  }
  async function statusMelden() {
    var s = await status();
    var alle = await self.clients.matchAll({ includeUncontrolled: true });
    alle.forEach(function (c) { c.postMessage(s); });
  }

  self.addEventListener('message', function (event) {
    var d = event.data || {};
    var arbeit = (async function () {
      if (d.typ === 'tokens') {
        for (var i = 0; i < (d.tokens || []).length; i++) await tokenMerken(d.tokens[i]);
        if (d.sync) await synchronisieren();
      } else if (d.typ === 'sync') {
        await synchronisieren();
      } else if (d.typ === 'abgemeldet') {
        // Niemand mehr angemeldet → gelesene Daten vom Gerät entfernen.
        // Die Warteschlange (eigene, noch nicht gesendete Eingaben) bleibt.
        await idbLeeren('antworten'); await idbLeeren('tokens'); tokens = {};
      } else if (d.typ === 'konflikt-verwerfen') {
        await idbDel('konflikte', d.nr);
      } else if (d.typ === 'konflikt-trotzdem') {
        var k = await idbGet('konflikte', d.nr);
        if (k && k.eintrag && (k.art === 'aendern' || k.art === 'upsert')) {
          var e = k.eintrag; delete e.nr; e.trotzdem = true; e.zeit = Date.now();
          await idbPut('warteschlange', e);
          await idbDel('konflikte', d.nr);
          await synchronisieren();
        }
      }
      var s = await status();
      if (event.source) event.source.postMessage(s);
    })();
    event.waitUntil(arbeit);
  });

  self.addEventListener('sync', function (event) {
    if (event.tag === 'ghd-offline-sync') event.waitUntil(synchronisieren());
  });

  // ---------- Anfragen verteilen ----------
  self.addEventListener('fetch', function (event) {
    var req = event.request;
    var url = new URL(req.url);

    if (url.hostname === SB_HOST) {
      if (url.pathname.indexOf('/rest/v1/') === 0 && url.pathname.indexOf('/rest/v1/rpc/') !== 0 && tabelleVon(url)) {
        if (req.method === 'GET') { event.respondWith(datenLesen(req)); return; }
        if (req.method === 'POST') { event.respondWith(datenSchreiben(req, 'neu', event)); return; }
        if (req.method === 'PATCH') { event.respondWith(datenSchreiben(req, 'aendern', event)); return; }
        if (req.method === 'DELETE') { event.respondWith(datenSchreiben(req, 'loeschen', event)); return; }
        return;
      }
      if (/^\/storage\/v1\/object\/(?!public\/|sign\/|authenticated\/|info\/|list\/|move$|copy$)/.test(url.pathname)
          && (req.method === 'POST' || req.method === 'PUT')) {
        event.respondWith(datenSchreiben(req, 'datei', event));
        return;
      }
      if (req.method === 'GET' && url.pathname.indexOf('/storage/v1/object/public/') === 0) {
        event.respondWith(netzZuerst(req, 6000, false));
        return;
      }
      return; // Anmeldung, Edge Functions, RPC: immer direkt ans Netz
    }

    if (req.method !== 'GET') return;
    if (req.url.indexOf(GEMEINSAM) === 0) { event.respondWith(netzZuerst(req, 4000, false)); return; }
    if (url.origin === self.location.origin) {
      if (req.mode === 'navigate') {
        if (url.pathname.indexOf(new URL(self.registration.scope).pathname) !== 0) return;
        event.respondWith(netzZuerst(req, 4000, true));
      } else {
        event.respondWith(netzZuerst(req, 4000, false));
      }
      return;
    }
    if (FREMD_ERLAUBT.indexOf(url.hostname) >= 0) event.respondWith(speicherZuerst(req, event));
  });
})();
