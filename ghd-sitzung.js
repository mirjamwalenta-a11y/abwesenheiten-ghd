// ============================================================
// GHD-SITZUNG — automatisch abmelden nach 15 Minuten ohne Bedienung
// Gilt für alle Great-Hair-Day-Apps unter derselben Adresse
// (mirjamwalenta-a11y.github.io): sie teilen sich Anmeldung und Speicher.
// Getippt in irgendeiner App = alle bleiben angemeldet; 15 Minuten nichts =
// überall abgemeldet, beim nächsten Öffnen wieder PIN.
// Einbinden im <head> VOR den App-Skripten:
//   <script src="https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-sitzung.js"></script>
// Ausnahme Stempel-Tablet: window.ghdSitzung.keinAutoAbmelden(true)
//
// OFFLINE MIT PIN (seit 2026-11-01): Nach der Anmeldung kann jede Person
// einmal eine Offline-PIN festlegen. Beim automatischen Abmelden wird die
// Anmeldung dann nicht weggeworfen, sondern VERSCHLÜSSELT im Gerät abgelegt
// („Tresor“) – die gemerkten Daten bleiben erhalten. Ohne Netz lässt sich
// der Tresor mit der PIN wieder öffnen; mit Netz gilt wie bisher der normale
// Login (die Anmeldung am Server wird beim Abmelden trotzdem beendet).
// Technik: RSA-OAEP-Schlüsselpaar pro Person; der private Schlüssel ist mit
// einem aus der PIN abgeleiteten Schlüssel (PBKDF2, 310 000 Runden)
// verschlüsselt, so kann beim Abmelden ohne PIN verschlossen, aber nur mit
// PIN geöffnet werden. 5 falsche Versuche → Tresor und Offline-Daten weg.
// Apps mit eigener Anmeldung (zusätzlich zu Supabase) geben ihre Speicher-Schlüssel an,
// die beim Abmelden gelöscht werden (localStorage und sessionStorage):
//   <script src="…/ghd-sitzung.js" data-schluessel="meine-app-session,meine-app-user"></script>
// ============================================================
(function () {
  var MINUTEN = 15;
  var KEY = "ghd-letzte-aktivitaet", AUSNAHME = "ghd-kein-auto-abmelden";
  var SB_URL = "https://wrxlaltgtgkdomklgrlj.supabase.co";
  var SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndyeGxhbHRndGdrZG9ta2xncmxqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQyNDYwMzYsImV4cCI6MjA5OTgyMjAzNn0.Bw8ch-EJb_cLYTwxHdpjUJWgoCjje3Jc32pB0yiBS8g"; // öffentlicher anon-Schlüssel
  var TOKEN = "sb-wrxlaltgtgkdomklgrlj-auth-token";
  var skript = document.currentScript;
  var EIGENE = ((skript && skript.getAttribute("data-schluessel")) || "").split(",").map(function (x) { return x.trim(); }).filter(Boolean);
  function ls(k, v) {
    try {
      if (v === undefined) return localStorage.getItem(k);
      if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v);
    } catch (e) { return null; }
  }
  function eigeneAngemeldet() {
    for (var i = 0; i < EIGENE.length; i++) {
      try { if (localStorage.getItem(EIGENE[i]) || sessionStorage.getItem(EIGENE[i])) return true; } catch (e) { /* egal */ }
    }
    return false;
  }
  function abmelden() {
    var roh = ls(TOKEN);
    // Erst merken, was verschlossen werden soll (synchron, bevor die App es liest) …
    var fuerTresor = schnappschuss();
    ls(TOKEN, null); ls(KEY, null);
    EIGENE.forEach(function (k) { ls(k, null); try { sessionStorage.removeItem(k); } catch (e) { /* egal */ } });
    try { sessionStorage.clear(); } catch (e) { /* egal */ }
    // … dann (asynchron) verschlüsselt ablegen, Server-Abmeldung, neu laden
    var fertig = false;
    var weiter = function () { if (fertig) return; fertig = true; serverAbmelden(roh); location.reload(); };
    setTimeout(weiter, 4000);
    tresorVerschliessen(fuerTresor).then(weiter, weiter);
  }
  function serverAbmelden(roh) {
    // Sitzung auch am Server beenden (Refresh-Token ungültig machen)
    try {
      var t = JSON.parse(roh || "null");
      if (t && t.access_token) fetch(SB_URL + "/auth/v1/logout?scope=local", { method: "POST", keepalive: true,
        headers: { apikey: SB_KEY, Authorization: "Bearer " + t.access_token } }).catch(function () {});
    } catch (e) { /* egal */ }
  }
  // ================= Offline-PIN / Tresor =================
  var PIN_KEY = 'ghd-offline-pin';           // { ident: { pub, priv, salt, iv, runden } }
  var TRESOR_KEY = 'ghd-tresor';             // [ { ident, pfad, zeit, iv, wk, ct } ]
  var FEHL_KEY = 'ghd-tresor-fehlversuche';
  var SPAETER_KEY = 'ghd-offline-pin-spaeter';
  var ENTSPERRT = 'ghd-offline-entsperrt';    // sessionStorage: in dieser Sitzung offline entsperrt
  var RUNDEN = 310000, MAX_FEHL = 5;
  var cs = window.crypto && window.crypto.subtle;
  function jget(k, d) { try { var v = JSON.parse(ls(k) || 'null'); return v === null ? d : v; } catch (e) { return d; } }
  function jset(k, v) { ls(k, v === null ? null : JSON.stringify(v)); }
  function b64(buf) { var s = '', a = new Uint8Array(buf); for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]); return btoa(s); }
  function unb64(t) { var s = atob(t), a = new Uint8Array(s.length); for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
  function zufall(n) { return crypto.getRandomValues(new Uint8Array(n)); }
  function aktuelleIdent() {
    var id = nutzerId();
    if (id) return 'u:' + id;
    if (eigeneAngemeldet()) return 'app:' + location.pathname.replace(/[^/]*$/, '') + EIGENE.join(',');
    return null;
  }
  function schnappschuss() {
    var ident = aktuelleIdent();
    if (!ident || !jget(PIN_KEY, {})[ident]) return null;
    var lokal = {}, sitzung = {};
    if (ls(TOKEN)) lokal[TOKEN] = ls(TOKEN);
    EIGENE.forEach(function (k) {
      if (ls(k)) lokal[k] = ls(k);
      try { var v = sessionStorage.getItem(k); if (v) sitzung[k] = v; } catch (e) { /* egal */ }
    });
    return { ident: ident, lokal: lokal, sitzung: sitzung };
  }
  async function pinSchluessel(pin, salt, runden) {
    var basis = await cs.importKey('raw', new TextEncoder().encode(pin), 'PBKDF2', false, ['deriveKey']);
    return cs.deriveKey({ name: 'PBKDF2', salt: salt, iterations: runden, hash: 'SHA-256' }, basis,
      { name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey']);
  }
  var RSA = { name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
  async function pinFestlegen(pin) {
    var ident = aktuelleIdent();
    if (!ident || !cs) throw new Error('Nicht angemeldet');
    var paar = await cs.generateKey(RSA, true, ['wrapKey', 'unwrapKey']);
    var salt = zufall(16), iv = zufall(12);
    var kek = await pinSchluessel(pin, salt, RUNDEN);
    var priv = await cs.wrapKey('pkcs8', paar.privateKey, kek, { name: 'AES-GCM', iv: iv });
    var pub = await cs.exportKey('jwk', paar.publicKey);
    var alle = jget(PIN_KEY, {});
    alle[ident] = { pub: pub, priv: b64(priv), salt: b64(salt), iv: b64(iv), runden: RUNDEN };
    jset(PIN_KEY, alle);
    // alte Tresore dieser Person passen nicht mehr zum neuen Schlüssel
    jset(TRESOR_KEY, jget(TRESOR_KEY, []).filter(function (t) { return t.ident !== ident; }));
  }
  async function tresorVerschliessen(snap) {
    if (!snap || !cs) return;
    var eintrag = jget(PIN_KEY, {})[snap.ident];
    if (!eintrag) return;
    var pub = await cs.importKey('jwk', eintrag.pub, RSA, false, ['wrapKey']);
    var dk = await cs.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
    var iv = zufall(12);
    var ct = await cs.encrypt({ name: 'AES-GCM', iv: iv }, dk, new TextEncoder().encode(JSON.stringify({ lokal: snap.lokal, sitzung: snap.sitzung })));
    var wk = await cs.wrapKey('raw', dk, pub, { name: 'RSA-OAEP' });
    var pfad = location.pathname;
    var liste = jget(TRESOR_KEY, []).filter(function (t) { return !(t.ident === snap.ident && t.pfad === pfad); });
    liste.push({ ident: snap.ident, pfad: pfad, zeit: Date.now(), iv: b64(iv), wk: b64(wk), ct: b64(ct) });
    jset(TRESOR_KEY, liste.slice(-10));
  }
  async function tresorOeffnen(pin) {
    var alle = jget(PIN_KEY, {}), liste = jget(TRESOR_KEY, []);
    for (var ident in alle) {
      var e = alle[ident];
      var eigene = liste.filter(function (t) { return t.ident === ident; });
      if (!eigene.length) continue;
      var priv;
      try {
        var kek = await pinSchluessel(pin, unb64(e.salt), e.runden || RUNDEN);
        priv = await cs.unwrapKey('pkcs8', unb64(e.priv), kek, { name: 'AES-GCM', iv: unb64(e.iv) }, RSA, false, ['unwrapKey']);
      } catch (x) { continue; } // falsche PIN für diese Person
      eigene.sort(function (a, b) { return a.zeit - b.zeit; });
      for (var i = 0; i < eigene.length; i++) {
        var t = eigene[i];
        try {
          var dk = await cs.unwrapKey('raw', unb64(t.wk), priv, { name: 'RSA-OAEP' }, { name: 'AES-GCM' }, false, ['decrypt']);
          var klar = JSON.parse(new TextDecoder().decode(await cs.decrypt({ name: 'AES-GCM', iv: unb64(t.iv) }, dk, unb64(t.ct))));
          Object.keys(klar.lokal || {}).forEach(function (k) { ls(k, klar.lokal[k]); });
          Object.keys(klar.sitzung || {}).forEach(function (k) { try { sessionStorage.setItem(k, klar.sitzung[k]); } catch (x) { /* egal */ } });
        } catch (x) { /* einzelner Eintrag kaputt – weiter */ }
      }
      return true;
    }
    return false;
  }
  function tresorDa() { return jget(TRESOR_KEY, []).length > 0; }
  function allesVergessen() {
    jset(TRESOR_KEY, null); jset(PIN_KEY, null); ls(FEHL_KEY, null);
    // gemerkte Daten im Service Worker löschen (ghd-offline-sw.js)
    try {
      if (navigator.serviceWorker && navigator.serviceWorker.controller) navigator.serviceWorker.controller.postMessage({ typ: 'abgemeldet' });
    } catch (e) { /* egal */ }
  }
  async function keinNetz() {
    if (!navigator.onLine) return true;
    try {
      var c = new AbortController(); var t = setTimeout(function () { c.abort(); }, 3500);
      await fetch(location.href.split('#')[0], { method: 'HEAD', cache: 'no-store', signal: c.signal });
      clearTimeout(t); return false;
    } catch (e) { return true; }
  }

  // ---- Oberfläche (eigene, schlichte Dialoge über der App) ----
  var SCHRIFT = 'font:500 15px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;';
  function el(tag, css, text) { var e = document.createElement(tag); if (css) e.style.cssText = css; if (text !== undefined) e.textContent = text; return e; }
  function knopf(text, dunkel) {
    var b = el('button', (dunkel ? 'background:#1c1917;color:#fff;border:0;' : 'background:#fff;color:#1c1917;border:1px solid #d6d3d1;')
      + 'border-radius:999px;padding:11px 16px;cursor:pointer;width:100%;margin-top:8px;' + SCHRIFT, text);
    b.type = 'button'; return b;
  }
  function pinFeld(platzhalter) {
    var i = el('input', 'width:100%;box-sizing:border-box;padding:12px;border:1px solid #d6d3d1;border-radius:10px;margin-top:8px;font:600 22px/1.2 system-ui;letter-spacing:.3em;text-align:center');
    i.type = 'password'; i.inputMode = 'numeric'; i.autocomplete = 'off'; i.maxLength = 8; i.placeholder = platzhalter;
    return i;
  }
  function dialog(id, titel, text) {
    var alt = document.getElementById(id); if (alt) alt.remove();
    var h = el('div', 'position:fixed;inset:0;z-index:2147483647;background:rgba(28,25,23,.55);display:flex;align-items:center;justify-content:center;padding:16px;');
    h.id = id;
    var box = el('div', 'background:#fff;color:#1c1917;width:100%;max-width:380px;border-radius:18px;padding:20px 18px;box-shadow:0 10px 40px rgba(0,0,0,.3);' + SCHRIFT);
    box.appendChild(el('div', 'font-weight:700;font-size:18px;margin-bottom:6px', titel));
    if (text) box.appendChild(el('div', 'color:#57534e;font-size:14px', text));
    h.appendChild(box);
    (document.body || document.documentElement).appendChild(h);
    return { huelle: h, box: box };
  }
  function pinEinrichtenZeigen() {
    var d = dialog('ghd-pin-einrichten', '📴 Offline-PIN festlegen',
      'Damit du die Apps auch ohne Internet öffnen kannst. 4–8 Ziffern, nicht deine Handy-PIN. Ohne Netz gibst du sie statt der Anmeldung ein.');
    var p1 = pinFeld('PIN'), p2 = pinFeld('PIN wiederholen');
    var fehler = el('div', 'color:#b91c1c;font-size:13px;min-height:18px;margin-top:6px');
    var ok = knopf('PIN speichern', true), nein = knopf('Später');
    [p1, p2, fehler, ok, nein].forEach(function (x) { d.box.appendChild(x); });
    ok.onclick = async function () {
      if (!/^\d{4,8}$/.test(p1.value)) { fehler.textContent = 'Bitte 4 bis 8 Ziffern.'; return; }
      if (p1.value !== p2.value) { fehler.textContent = 'Die beiden PINs sind nicht gleich.'; return; }
      ok.disabled = true; ok.textContent = 'Wird gespeichert …';
      try { await pinFestlegen(p1.value); d.huelle.remove(); hinweisWeg(); }
      catch (e) { fehler.textContent = 'Ging nicht: ' + e.message; ok.disabled = false; ok.textContent = 'PIN speichern'; }
    };
    nein.onclick = function () { ls(SPAETER_KEY, String(Date.now())); d.huelle.remove(); hinweisWeg(); };
    setTimeout(function () { p1.focus(); }, 50);
  }
  function hinweisWeg() { var h = document.getElementById('ghd-pin-hinweis'); if (h) h.remove(); }
  function pinHinweisZeigen() {
    if (document.getElementById('ghd-pin-hinweis')) return;
    var b = el('button', 'position:fixed;right:12px;bottom:calc(60px + env(safe-area-inset-bottom));z-index:2147483640;background:#2E5D4B;color:#fff;border:0;border-radius:999px;padding:9px 14px;box-shadow:0 4px 16px rgba(0,0,0,.2);cursor:pointer;' + SCHRIFT + 'font-size:13px', '📴 Offline-PIN festlegen');
    b.id = 'ghd-pin-hinweis'; b.type = 'button'; b.onclick = pinEinrichtenZeigen;
    (document.body || document.documentElement).appendChild(b);
  }
  function entsperrenZeigen() {
    if (document.getElementById('ghd-entsperren')) return;
    var d = dialog('ghd-entsperren', '📴 Offline – mit PIN entsperren',
      'Kein Internet. Mit deiner Offline-PIN siehst du den zuletzt geladenen Stand und kannst weiterarbeiten – Änderungen werden hochgeladen, sobald wieder Netz da ist.');
    var p = pinFeld('Offline-PIN');
    var fehler = el('div', 'color:#b91c1c;font-size:13px;min-height:18px;margin-top:6px');
    var ok = knopf('Entsperren', true), abbr = knopf('Abbrechen');
    var vergessen = el('button', 'background:none;border:0;color:#78716c;text-decoration:underline;cursor:pointer;margin-top:10px;width:100%;' + SCHRIFT + 'font-size:13px', 'PIN vergessen / Offline-Daten von diesem Gerät löschen');
    vergessen.type = 'button';
    [p, fehler, ok, abbr, vergessen].forEach(function (x) { d.box.appendChild(x); });
    async function los() {
      if (!p.value) return;
      ok.disabled = true; ok.textContent = 'Wird geprüft …';
      var offen = false;
      try { offen = await tresorOeffnen(p.value); } catch (e) { offen = false; }
      if (offen) {
        ls(FEHL_KEY, null); ls(KEY, String(Date.now()));
        try { sessionStorage.setItem(ENTSPERRT, '1'); } catch (e) { /* egal */ }
        location.reload(); return;
      }
      var n = (+ls(FEHL_KEY) || 0) + 1;
      ls(FEHL_KEY, String(n));
      if (n >= MAX_FEHL) {
        allesVergessen(); d.huelle.remove();
        alert('5 falsche Versuche – die Offline-Daten wurden zur Sicherheit von diesem Gerät gelöscht. Mit Internet kannst du dich normal anmelden.');
        return;
      }
      p.value = ''; ok.disabled = false; ok.textContent = 'Entsperren';
      fehler.textContent = 'Falsche PIN. Noch ' + (MAX_FEHL - n) + (MAX_FEHL - n === 1 ? ' Versuch.' : ' Versuche.');
    }
    ok.onclick = los;
    p.addEventListener('keydown', function (e) { if (e.key === 'Enter') los(); });
    abbr.onclick = function () { d.huelle.remove(); };
    vergessen.onclick = function () {
      if (!confirm('Offline-PIN und alle offline gemerkten Daten von diesem Gerät löschen? (Am Server geht nichts verloren.)')) return;
      allesVergessen(); d.huelle.remove();
    };
    setTimeout(function () { p.focus(); }, 50);
  }
  async function offlineStart() {
    if (!cs) return;
    var angemeldet = !!(ls(TOKEN) || eigeneAngemeldet());
    if (angemeldet) {
      var ident = aktuelleIdent();
      var spaeter = +ls(SPAETER_KEY) || 0;
      if (ident && !jget(PIN_KEY, {})[ident] && Date.now() - spaeter > 7 * 86400000 && navigator.serviceWorker) {
        if (document.body) pinHinweisZeigen(); else document.addEventListener('DOMContentLoaded', pinHinweisZeigen);
      }
      return;
    }
    if (tresorDa() && await keinNetz()) {
      if (document.body) entsperrenZeigen(); else document.addEventListener('DOMContentLoaded', entsperrenZeigen);
    }
  }
  addEventListener('offline', function () { if (!ls(TOKEN) && !eigeneAngemeldet() && tresorDa()) entsperrenZeigen(); });

  function nutzerId() { try { var t = JSON.parse(ls(TOKEN) || "null"); return (t && t.user && t.user.id) || null; } catch (e) { return null; } }
  function pruefen() {
    if (!ls(TOKEN) && !eigeneAngemeldet()) return;
    if (ls(AUSNAHME) && ls(AUSNAHME) === nutzerId()) return; // angemeldet ist der Tablet-Zugang
    if (ls(AUSNAHME)) ls(AUSNAHME, null);                   // jemand anderer → Ausnahme gilt nicht mehr
    var letzte = +ls(KEY) || 0;
    if (!letzte) { ls(KEY, String(Date.now())); return; }
    if (Date.now() - letzte > MINUTEN * 60000) abmelden();
  }
  pruefen(); // gleich beim Öffnen – bevor die App die Anmeldung liest
  setTimeout(offlineStart, 0);
  var zuletzt = 0;
  function aktiv() { var j = Date.now(); if (j - zuletzt > 5000) { zuletzt = j; ls(KEY, String(j)); } }
  ["pointerdown", "keydown", "touchstart", "wheel"].forEach(function (e) { addEventListener(e, aktiv, { passive: true, capture: true }); });
  setInterval(pruefen, 20000);
  document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible") pruefen(); });
  // Neue Version veröffentlicht? (GitHub hält Seiten bis zu 10 min zwischen, Handys oft länger)
  // → Hinweis oben „Neue Version – tippen zum Aktualisieren“
  function hinweis() {
    if (document.getElementById("ghd-neue-version")) return;
    var d = document.createElement("button");
    d.id = "ghd-neue-version";
    d.textContent = "✨ Neue Version verfügbar – tippen zum Aktualisieren";
    d.style.cssText = "position:fixed;top:10px;left:50%;transform:translateX(-50%);z-index:2147483647;background:#896C32;color:#fff;border:0;border-radius:999px;padding:10px 18px;font:600 14px/1.2 Poppins,system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.25);max-width:92vw";
    d.onclick = function () { location.reload(); };
    (document.body || document.documentElement).appendChild(d);
  }
  function versionPruefen() {
    if (location.protocol !== "https:" && location.hostname !== "127.0.0.1") return;
    var geladen = Date.parse(document.lastModified);
    if (!geladen) return;
    fetch(location.href.split("#")[0], { method: "HEAD", cache: "no-store" }).then(function (r) {
      var aktuell = Date.parse(r.headers.get("last-modified") || "");
      if (aktuell && aktuell - geladen > 60000) hinweis();
    }).catch(function () {});
  }
  setTimeout(versionPruefen, 10000);
  setInterval(versionPruefen, 5 * 60000);
  document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible") versionPruefen(); });
  window.ghdSitzung = {
    minuten: MINUTEN,
    // nur für den gerade angemeldeten Zugang (Stempel-Tablet); meldet sich jemand anderer an, gilt sie nicht mehr
    // Abmelden wie nach 15 min (mit Offline-Tresor, falls PIN festgelegt) – für Apps mit eigener Abmelde-Zeit
    sperren: abmelden,
    offlinePinFestlegen: pinEinrichtenZeigen,
    offlineEntsperrt: function () { try { return sessionStorage.getItem(ENTSPERRT) === '1'; } catch (e) { return false; } },
    tresorVorhanden: tresorDa,
    keinAutoAbmelden: function (an) { var id = nutzerId(); ls(AUSNAHME, an && id ? id : null); if (!an) ls(KEY, String(Date.now())); },
  };
})();
