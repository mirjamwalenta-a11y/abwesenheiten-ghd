// ============================================================
// GHD-OFFLINE — Seiten-Teil, gemeinsam für alle Great-Hair-Day-Apps
// (Gegenstück zu ghd-offline-sw.js; Erklärung der Regeln dort.)
//
// Einbinden im <head>, NACH supabase-js (falls die App es nutzt) und VOR
// den App-Skripten:
//   <script src="https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-offline.js"></script>
// Optionen als Attribute:
//   data-sw="sw.js"                 Pfad zur sw.js der App (Standard: sw.js neben der Seite)
//   data-schluessel="a,b"           eigene Anmelde-Schlüssel der App (localStorage/sessionStorage),
//                                   solange einer davon gesetzt ist, gilt jemand als angemeldet
//   data-oeffentlich                App ohne Anmeldung → gemerkte Daten nie automatisch löschen
//
// Was es tut:
//  - meldet den Service Worker an,
//  - sorgt dafür, dass supabase-js ohne Netz die gespeicherte Anmeldung
//    liefert, statt bis zu 30 s an der Token-Erneuerung zu hängen
//    (die Rechte prüft weiterhin nur der Server: ohne Netz kommen nur
//    Daten, die diese Person auf diesem Gerät schon geladen hatte),
//  - reicht frische Anmelde-Token an den Service Worker weiter, damit er
//    gespeicherte Änderungen später im Namen derselben Person nachschickt,
//  - zeigt unten an: offline / „3 Änderungen warten“ / Konflikte.
// ============================================================
(function () {
  'use strict';
  if (window.ghdOffline) return;
  var skript = document.currentScript;
  var attr = function (n) { return skript ? skript.getAttribute(n) : null; };
  var EIGENE = (attr('data-schluessel') || '').split(',').map(function (x) { return x.trim(); }).filter(Boolean);
  var OEFFENTLICH = skript ? skript.hasAttribute('data-oeffentlich') : false;
  var SW_PFAD = attr('data-sw') || 'sw.js';
  var SB_TOKEN = 'sb-wrxlaltgtgkdomklgrlj-auth-token';
  var swDa = 'serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1');
  var stand = { wartend: 0, konflikte: [] };

  // ---------- supabase-js: ohne Netz gespeicherte Anmeldung verwenden ----------
  function gespeicherteSitzung() {
    try {
      var s = JSON.parse(localStorage.getItem(SB_TOKEN) || 'null');
      if (s && s.currentSession) s = s.currentSession;
      return s && s.access_token && s.refresh_token ? s : null;
    } catch (e) { return null; }
  }
  function getSessionAbsichern(auth) {
    if (!auth || auth.__ghdOffline || typeof auth.getSession !== 'function') return;
    var original = auth.getSession.bind(auth);
    auth.getSession = function () {
      var s = gespeicherteSitzung();
      if (s && !navigator.onLine) return Promise.resolve({ data: { session: s }, error: null });
      if (!s) return original();
      // Schwaches Netz: nicht ewig auf die Token-Erneuerung warten
      return Promise.race([
        original(),
        new Promise(function (ok) { setTimeout(function () { ok(null); }, 6000); })
      ]).then(function (r) {
        if (r && r.data && r.data.session) return r;
        var s2 = gespeicherteSitzung();
        if (s2 && (r === null || (r && r.error && !navigator.onLine) || (r && r.error && /fetch|network/i.test(String(r.error.message || r.error.name))))) {
          return { data: { session: s2 }, error: null };
        }
        return r || original();
      });
    };
    auth.__ghdOffline = true;
  }
  function supabaseAbsichern() {
    var sb = window.supabase;
    if (!sb || typeof sb.createClient !== 'function' || sb.createClient.__ghdOffline) return;
    var original = sb.createClient;
    var neu = function () {
      var client = original.apply(this, arguments);
      try { getSessionAbsichern(client.auth); } catch (e) { /* egal */ }
      return client;
    };
    neu.__ghdOffline = true;
    try { sb.createClient = neu; } catch (e) { /* eingefroren – dann eben nicht */ }
  }
  supabaseAbsichern();
  document.addEventListener('DOMContentLoaded', supabaseAbsichern);

  // ---------- Anmelde-Token einsammeln ----------
  function istJwt(s) { return typeof s === 'string' && /^eyJ[\w-]*\.[\w-]+\.[\w-]+$/.test(s); }
  function nutzlast(t) {
    try {
      var s = t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      while (s.length % 4) s += '=';
      return JSON.parse(atob(s));
    } catch (e) { return null; }
  }
  function tokensSammeln() {
    var gefunden = [];
    [localStorage, sessionStorage].forEach(function (speicher) {
      try {
        for (var i = 0; i < speicher.length; i++) {
          var v = speicher.getItem(speicher.key(i));
          if (!v) continue;
          if (istJwt(v)) gefunden.push(v);
          else if (v.charAt(0) === '{') {
            try {
              var o = JSON.parse(v);
              if (o && istJwt(o.access_token)) gefunden.push(o.access_token);
              if (o && o.currentSession && istJwt(o.currentSession.access_token)) gefunden.push(o.currentSession.access_token);
            } catch (e) { /* kein JSON */ }
          }
        }
      } catch (e) { /* Speicher gesperrt */ }
    });
    return gefunden.filter(function (t) { var p = nutzlast(t); return p && p.sub && p.exp; });
  }
  function jemandAngemeldet() {
    if (tokensSammeln().length) return true;
    for (var i = 0; i < EIGENE.length; i++) {
      try { if (localStorage.getItem(EIGENE[i]) || sessionStorage.getItem(EIGENE[i])) return true; } catch (e) { /* egal */ }
    }
    return false;
  }

  // ---------- Service Worker ----------
  function senden(nachricht) {
    if (!swDa) return;
    navigator.serviceWorker.ready.then(function (reg) { if (reg.active) reg.active.postMessage(nachricht); });
  }
  function abgleichen() {
    if (!navigator.onLine) return;
    senden({ typ: 'tokens', tokens: tokensSammeln().filter(function (t) { return nutzlast(t).exp * 1000 > Date.now(); }), sync: true });
  }
  if (swDa) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register(SW_PFAD).catch(function () {});
    });
    navigator.serviceWorker.addEventListener('message', function (e) {
      if (e.data && e.data.typ === 'ghd-offline-status') { stand = e.data; anzeigen(); }
    });
    navigator.serviceWorker.ready.then(function () {
      if (!OEFFENTLICH && !jemandAngemeldet()) senden({ typ: 'abgemeldet' });
      abgleichen();
      senden({ typ: 'status' });
    });
    window.addEventListener('online', abgleichen);
    window.addEventListener('storage', function () { setTimeout(abgleichen, 200); });
    document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') abgleichen(); });
    setInterval(function () { if (stand.wartend > 0) abgleichen(); }, 30000);
  }

  // ---------- Anzeige ----------
  function el(tag, css, text) { var e = document.createElement(tag); if (css) e.style.cssText = css; if (text !== undefined) e.textContent = text; return e; }
  var SCHRIFT = 'font:500 13px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;';
  function anzeigen() {
    if (!document.body) { document.addEventListener('DOMContentLoaded', anzeigen, { once: true }); return; }
    var leiste = document.getElementById('ghd-offline-leiste');
    var k = (stand.konflikte || []).length, w = stand.wartend || 0, off = !navigator.onLine;
    var text = '', farbe = '#2E5D4B';
    if (k) { text = '⚠️ ' + k + (k === 1 ? ' Änderung wurde' : ' Änderungen wurden') + ' nicht übernommen – tippen zum Ansehen'; farbe = '#9a3412'; }
    else if (w && off) text = 'Offline – ' + w + (w === 1 ? ' Änderung wartet' : ' Änderungen warten') + ' im Handy und ' + (w === 1 ? 'wird' : 'werden') + ' automatisch hochgeladen';
    else if (w) text = '⏳ ' + w + (w === 1 ? ' Änderung wird' : ' Änderungen werden') + ' hochgeladen …';
    else if (off) text = 'Offline – gezeigt wird der zuletzt geladene Stand';
    if (!text) { if (leiste) leiste.remove(); return; }
    if (!leiste) {
      leiste = el('button', 'position:fixed;left:50%;transform:translateX(-50%);bottom:calc(10px + env(safe-area-inset-bottom));z-index:2147483646;'
        + 'border:0;border-radius:999px;padding:8px 16px;color:#fff;max-width:94vw;box-shadow:0 4px 16px rgba(0,0,0,.2);' + SCHRIFT);
      leiste.id = 'ghd-offline-leiste';
      leiste.type = 'button';
      leiste.addEventListener('click', function () { if ((stand.konflikte || []).length) konflikteZeigen(); });
      document.body.appendChild(leiste);
    }
    leiste.style.background = farbe;
    leiste.style.cursor = k ? 'pointer' : 'default';
    leiste.textContent = text;
  }
  function wertText(v) {
    if (v === null || v === undefined) return '—';
    if (typeof v === 'string') return v.length > 300 ? v.slice(0, 300) + ' …' : v;
    var s = JSON.stringify(v, null, 1);
    return s.length > 600 ? s.slice(0, 600) + ' …' : s;
  }
  function tabelle(zeilen) {
    var t = el('div', 'background:#f5f5f4;border-radius:8px;padding:6px 8px;margin:2px 0;font-size:12px');
    zeilen.forEach(function (z) {
      var r = el('div', 'display:flex;gap:8px;padding:2px 0;word-break:break-word');
      r.appendChild(el('span', 'color:#78716c;min-width:30%;flex:0 0 auto;max-width:40%', z[0]));
      r.appendChild(el('span', 'white-space:pre-wrap', z[1]));
      t.appendChild(r);
    });
    return t;
  }
  function konflikteZeigen() {
    var alt = document.getElementById('ghd-offline-dialog');
    if (alt) alt.remove();
    var huelle = el('div', 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,.45);display:flex;align-items:flex-end;justify-content:center;');
    huelle.id = 'ghd-offline-dialog';
    var box = el('div', 'background:#fff;color:#1c1917;width:100%;max-width:520px;max-height:85vh;overflow:auto;border-radius:16px 16px 0 0;padding:18px 16px calc(18px + env(safe-area-inset-bottom));' + SCHRIFT);
    box.appendChild(el('div', 'font-weight:700;font-size:16px;margin-bottom:4px', 'Nicht übernommene Änderungen'));
    box.appendChild(el('div', 'color:#57534e;margin-bottom:12px', 'Damit nichts überschrieben wird, wurden diese Offline-Änderungen nicht gespeichert. Bitte prüfen und bei Bedarf neu eingeben.'));
    (stand.konflikte || []).forEach(function (k) {
      var karte = el('div', 'border:1px solid #e7e5e4;border-radius:12px;padding:12px;margin-bottom:10px');
      var art = { neu: 'Neuer Eintrag', upsert: 'Eintrag', aendern: 'Änderung', loeschen: 'Löschen', datei: 'Datei-Upload' }[k.art] || k.art;
      karte.appendChild(el('div', 'font-weight:600', art + (k.tabelle ? ' · ' + k.tabelle : '') + ' · ' + new Date(k.zeit).toLocaleString('de-AT')));
      karte.appendChild(el('div', 'color:#9a3412;margin:4px 0 8px', k.grund));
      var vorher = Array.isArray(k.vorher) && k.vorher.length === 1 ? k.vorher[0] : null;
      var jetzt = Array.isArray(k.server) ? (k.server.length === 1 ? k.server[0] : null) : (k.server || null);
      if (vorher && Array.isArray(k.server) && k.server.length === 0) {
        karte.appendChild(el('div', 'margin:2px 0', 'Der Eintrag wurde inzwischen von jemand anderem gelöscht.'));
      }
      if (k.art !== 'loeschen' && k.meine && typeof k.meine === 'object' && !Array.isArray(k.meine)) {
        karte.appendChild(el('div', 'font-weight:600;margin-top:4px', 'Deine Eingabe:'));
        karte.appendChild(tabelle(Object.keys(k.meine).map(function (f) { return [f, wertText(k.meine[f])]; })));
      } else if (k.art !== 'loeschen') {
        karte.appendChild(el('div', 'font-weight:600;margin-top:4px', 'Deine Eingabe:'));
        karte.appendChild(el('pre', 'white-space:pre-wrap;word-break:break-word;background:#f5f5f4;border-radius:8px;padding:8px;margin:2px 0;font-size:12px', wertText(k.meine)));
      }
      if (vorher && jetzt) {
        var geaendert = Object.keys(jetzt).filter(function (f) { return JSON.stringify(jetzt[f]) !== JSON.stringify(vorher[f]); });
        if (geaendert.length) {
          karte.appendChild(el('div', 'font-weight:600;margin-top:6px', 'Inzwischen von jemand anderem geändert:'));
          karte.appendChild(tabelle(geaendert.map(function (f) { return [f, wertText(vorher[f]) + '  →  ' + wertText(jetzt[f])]; })));
        }
      } else if (k.server) {
        karte.appendChild(el('div', 'font-weight:600;margin-top:4px', 'Jetzt am Server:'));
        karte.appendChild(el('pre', 'white-space:pre-wrap;word-break:break-word;background:#f5f5f4;border-radius:8px;padding:8px;margin:2px 0;font-size:12px', wertText(k.server)));
      }
      var knoepfe = el('div', 'display:flex;gap:8px;flex-wrap:wrap;margin-top:8px');
      var weg = el('button', 'border:1px solid #d6d3d1;background:#fff;border-radius:999px;padding:8px 14px;cursor:pointer;' + SCHRIFT, 'Verwerfen');
      weg.type = 'button';
      weg.onclick = function () { senden({ typ: 'konflikt-verwerfen', nr: k.nr }); karte.remove(); };
      knoepfe.appendChild(weg);
      if ((k.art === 'aendern' || k.art === 'upsert') && k.server) {
        var dennoch = el('button', 'border:0;background:#1c1917;color:#fff;border-radius:999px;padding:8px 14px;cursor:pointer;' + SCHRIFT, 'Meine Version trotzdem speichern');
        dennoch.type = 'button';
        dennoch.onclick = function () {
          if (!confirm('Damit wird die Änderung der anderen Person überschrieben. Wirklich speichern?')) return;
          senden({ typ: 'konflikt-trotzdem', nr: k.nr }); karte.remove();
        };
        knoepfe.appendChild(dennoch);
      }
      karte.appendChild(knoepfe);
      box.appendChild(karte);
    });
    var zu = el('button', 'width:100%;border:0;background:#e7e5e4;border-radius:999px;padding:10px;margin-top:4px;cursor:pointer;' + SCHRIFT, 'Schließen');
    zu.type = 'button';
    zu.onclick = function () { huelle.remove(); };
    box.appendChild(zu);
    huelle.appendChild(box);
    huelle.addEventListener('click', function (e) { if (e.target === huelle) huelle.remove(); });
    document.body.appendChild(huelle);
  }
  window.addEventListener('online', anzeigen);
  window.addEventListener('offline', anzeigen);
  document.addEventListener('DOMContentLoaded', anzeigen);

  window.ghdOffline = {
    gespeicherteSitzung: gespeicherteSitzung,
    jetztAbgleichen: abgleichen,
    konflikteZeigen: konflikteZeigen,
    stand: function () { return stand; }
  };
})();
