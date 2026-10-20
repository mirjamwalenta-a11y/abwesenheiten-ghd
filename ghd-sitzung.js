// ============================================================
// GHD-SITZUNG — automatisch abmelden nach 15 Minuten ohne Bedienung
// Gilt für alle Great-Hair-Day-Apps unter derselben Adresse
// (mirjamwalenta-a11y.github.io): sie teilen sich Anmeldung und Speicher.
// Getippt in irgendeiner App = alle bleiben angemeldet; 15 Minuten nichts =
// überall abgemeldet, beim nächsten Öffnen wieder PIN.
// Einbinden im <head> VOR den App-Skripten:
//   <script src="https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-sitzung.js"></script>
// Ausnahme Stempel-Tablet: window.ghdSitzung.keinAutoAbmelden(true)
// OHNE NETZ (festgelegt 2026-10-20, Variante „sperren statt abmelden“):
// Anmelden kann nur der Server prüfen. Damit man offline nicht ausgesperrt ist,
// wird nach 15 Minuten ohne Netz nicht abgemeldet, sondern GESPERRT. Entsperrt
// wird mit einem Geräte-Code, den man vorher (mit Netz, angemeldet) festlegt –
// gespeichert ist nur ein PBKDF2-Hash, nie der Code selbst. Der Code gibt keine
// neuen Rechte: er öffnet nur die schon vorhandene Anmeldung wieder, alle Rechte
// prüft weiterhin der Server. 5 falsche Versuche = richtig abmelden.
// Kommt das Netz zurück, während gesperrt ist → richtig abmelden.
// Ohne festgelegten Code verhält sich alles wie bisher (abmelden).

// Apps mit eigener Anmeldung (zusätzlich zu Supabase) geben ihre Speicher-Schlüssel an,
// die beim Abmelden gelöscht werden (localStorage und sessionStorage):
//   <script src="…/ghd-sitzung.js" data-schluessel="meine-app-session,meine-app-user"></script>
// ============================================================
(function () {
  var MINUTEN = 15;
  var KEY = "ghd-letzte-aktivitaet", AUSNAHME = "ghd-kein-auto-abmelden";
  var SPERRE = "ghd-gesperrt", CODES = "ghd-offline-code", FEHL = "ghd-gesperrt-fehlversuche", SPAETER = "ghd-offline-code-spaeter";
  var MAX_FEHL = 5, RUNDEN = 210000;
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
    ls(TOKEN, null); ls(KEY, null); ls(SPERRE, null); ls(FEHL, null);
    EIGENE.forEach(function (k) { ls(k, null); try { sessionStorage.removeItem(k); } catch (e) { /* egal */ } });
    try { sessionStorage.clear(); } catch (e) { /* egal */ }
    // Sitzung auch am Server beenden (Refresh-Token ungültig machen)
    try {
      var t = JSON.parse(roh || "null");
      if (t && t.access_token) fetch(SB_URL + "/auth/v1/logout?scope=local", { method: "POST", keepalive: true,
        headers: { apikey: SB_KEY, Authorization: "Bearer " + t.access_token } }).catch(function () {});
    } catch (e) { /* egal */ }
    location.reload();
  }
  function nutzerId() { try { var t = JSON.parse(ls(TOKEN) || "null"); return (t && t.user && t.user.id) || null; } catch (e) { return null; } }
  function pruefen() {
    if (!ls(TOKEN) && !eigeneAngemeldet()) { if (ls(SPERRE)) ls(SPERRE, null); sperreAnzeigen(false); return; }
    if (ls(SPERRE)) {
      if (navigator.onLine || !codeEintrag()) { abmelden(); return; } // Netz wieder da (oder kein Code) → richtig abmelden
      sperreAnzeigen(true); return;
    }
    sperreAnzeigen(false);
    if (ls(AUSNAHME) && ls(AUSNAHME) === nutzerId()) return; // angemeldet ist der Tablet-Zugang
    if (ls(AUSNAHME)) ls(AUSNAHME, null);                   // jemand anderer → Ausnahme gilt nicht mehr
    var letzte = +ls(KEY) || 0;
    if (!letzte) { ls(KEY, String(Date.now())); return; }
    if (Date.now() - letzte > MINUTEN * 60000) {
      if (!navigator.onLine && codeEintrag()) { ls(SPERRE, "1"); sperreAnzeigen(true); }
      else abmelden();
    }
    codeAngebotPruefen();
  }

  // ---------- Geräte-Code (nur Hash, pro angemeldeter Person) ----------
  function wer() {
    var id = nutzerId();
    if (id) return "u:" + id;
    for (var i = 0; i < EIGENE.length; i++) { var v = ls(EIGENE[i]); if (v) return "e:" + EIGENE[i] + ":" + kurz(v); }
    return null;
  }
  function kurz(v) { var h = 0; for (var i = 0; i < v.length; i++) h = (h * 31 + v.charCodeAt(i)) | 0; return (h >>> 0).toString(36); }
  function alleCodes() { try { return JSON.parse(ls(CODES) || "{}") || {}; } catch (e) { return {}; } }
  function codeEintrag() { var w = wer(); return w ? alleCodes()[w] || null : null; }
  var kryptoDa = !!(window.crypto && crypto.subtle && window.TextEncoder);
  function b64(buf) { return btoa(String.fromCharCode.apply(null, new Uint8Array(buf))); }
  function ausB64(t) { return Uint8Array.from(atob(t), function (c) { return c.charCodeAt(0); }); }
  function ableiten(code, salz, runden) {
    return crypto.subtle.importKey("raw", new TextEncoder().encode(code), "PBKDF2", false, ["deriveBits"]).then(function (k) {
      return crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: salz, iterations: runden }, k, 256);
    }).then(b64);
  }
  function codeSpeichern(code) {
    var w = wer(); if (!w) return Promise.reject(new Error("nicht angemeldet"));
    var salz = crypto.getRandomValues(new Uint8Array(16));
    return ableiten(code, salz, RUNDEN).then(function (hash) {
      var alle = alleCodes(); alle[w] = { salz: b64(salz), hash: hash, runden: RUNDEN }; ls(CODES, JSON.stringify(alle));
    });
  }
  function codePruefen(code) {
    var e = codeEintrag(); if (!e) return Promise.resolve(false);
    return ableiten(code, ausB64(e.salz), e.runden).then(function (h) { return h === e.hash; });
  }

  // ---------- Anzeige: Sperre und Angebot „Code festlegen“ ----------
  var SCHRIFT = "font:500 15px/1.4 Poppins,system-ui,sans-serif;";
  function knopf(text, dunkel) {
    var b = document.createElement("button"); b.type = "button"; b.textContent = text;
    b.style.cssText = "width:100%;border:0;border-radius:12px;padding:13px;margin-top:10px;cursor:pointer;" + SCHRIFT + (dunkel ? "background:#896C32;color:#fff;font-weight:700" : "background:#F0E9D8;color:#211D17");
    return b;
  }
  function feld(platzhalter) {
    var f = document.createElement("input"); f.type = "password"; f.inputMode = "numeric"; f.autocomplete = "off"; f.maxLength = 8; f.placeholder = platzhalter;
    f.style.cssText = "width:100%;box-sizing:border-box;border:1px solid #E4DBC5;border-radius:12px;padding:13px;margin-top:10px;text-align:center;letter-spacing:.3em;background:#fff;color:#211D17;" + SCHRIFT;
    return f;
  }
  function huelle(id) {
    var h = document.createElement("div"); h.id = id;
    h.style.cssText = "position:fixed;inset:0;z-index:2147483647;background:#F8F4EA;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box";
    var box = document.createElement("div"); box.style.cssText = "width:100%;max-width:340px;text-align:center;color:#211D17;" + SCHRIFT;
    h.appendChild(box); return { h: h, box: box };
  }
  function text(box, inhalt, css) { var d = document.createElement("div"); d.textContent = inhalt; d.style.cssText = css || ""; box.appendChild(d); return d; }
  function sperreAnzeigen(an) {
    var da = document.getElementById("ghd-sperre");
    if (!an) { if (da) da.remove(); return; }
    if (da) return;
    if (!document.body) { document.addEventListener("DOMContentLoaded", function () { if (ls(SPERRE)) sperreAnzeigen(true); }, { once: true }); return; }
    var x = huelle("ghd-sperre"), box = x.box;
    text(box, "🔒", "font-size:40px");
    text(box, "Gesperrt", "font-weight:700;font-size:20px;margin-top:6px");
    text(box, "Ohne Netz – mit deinem Geräte-Code entsperren.", "color:#7C7565;margin-top:4px");
    var f = feld("Geräte-Code");
    var fehler = text(box, "", "color:#B23A2E;min-height:1.4em;margin-top:8px;font-size:13px");
    box.insertBefore(f, fehler);
    var ok = knopf("Entsperren", true), raus = knopf("Abmelden", false);
    box.appendChild(ok); box.appendChild(raus);
    function versuchen() {
      if (!f.value) return;
      ok.disabled = true;
      codePruefen(f.value).then(function (richtig) {
        ok.disabled = false;
        if (richtig) { ls(SPERRE, null); ls(FEHL, null); ls(KEY, String(Date.now())); sperreAnzeigen(false); return; }
        var n = (+ls(FEHL) || 0) + 1; ls(FEHL, String(n));
        if (n >= MAX_FEHL) { abmelden(); return; }
        f.value = ""; f.focus();
        fehler.textContent = "Code falsch – noch " + (MAX_FEHL - n) + (MAX_FEHL - n === 1 ? " Versuch" : " Versuche") + ", dann wird abgemeldet.";
      }, function () { ok.disabled = false; fehler.textContent = "Entsperren klappt auf diesem Gerät nicht."; });
    }
    ok.onclick = versuchen;
    f.addEventListener("keydown", function (e) { if (e.key === "Enter") versuchen(); });
    raus.onclick = abmelden;
    document.body.appendChild(x.h);
    setTimeout(function () { f.focus(); }, 50);
  }
  function codeAngebotPruefen() {
    var b = document.getElementById("ghd-code-angebot");
    var zeigen = kryptoDa && navigator.onLine && wer() && !codeEintrag() && !ls(SPERRE)
      && !(ls(AUSNAHME) && ls(AUSNAHME) === nutzerId());
    try { if (sessionStorage.getItem(SPAETER)) zeigen = false; } catch (e) { /* egal */ }
    if (!zeigen) { if (b) b.remove(); return; }
    if (b || !document.body) return;
    b = document.createElement("button"); b.id = "ghd-code-angebot"; b.type = "button";
    b.textContent = "🔒 Geräte-Code festlegen, um auch ohne Netz weiterzuarbeiten";
    b.style.cssText = "position:fixed;left:50%;transform:translateX(-50%);bottom:calc(56px + env(safe-area-inset-bottom));z-index:2147483645;border:0;border-radius:999px;padding:9px 16px;background:#211D17;color:#fff;max-width:94vw;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.2);font:500 13px/1.4 Poppins,system-ui,sans-serif";
    b.onclick = codeFestlegen;
    document.body.appendChild(b);
  }
  function codeFestlegen() {
    if (!kryptoDa || !wer() || document.getElementById("ghd-code-dialog")) return;
    var alt = document.getElementById("ghd-code-angebot"); if (alt) alt.remove();
    var x = huelle("ghd-code-dialog"), box = x.box;
    x.h.style.background = "rgba(33,29,23,.55)";
    box.style.cssText += ";background:#F8F4EA;border-radius:16px;padding:22px 18px";
    text(box, "Geräte-Code fürs Offline-Arbeiten", "font-weight:700;font-size:17px");
    text(box, "Ohne Netz wirst du nach 15 Minuten nicht abgemeldet, sondern gesperrt – und entsperrst mit diesem Code. 4 bis 8 Ziffern, nur auf diesem Gerät gespeichert (verschlüsselt).", "color:#7C7565;font-size:13px;margin-top:6px");
    var f1 = feld("Code"), f2 = feld("Code wiederholen");
    box.appendChild(f1); box.appendChild(f2);
    var fehler = text(box, "", "color:#B23A2E;min-height:1.4em;margin-top:8px;font-size:13px");
    var ok = knopf("Speichern", true), spaeter = knopf("Später", false);
    box.appendChild(ok); box.appendChild(spaeter);
    ok.onclick = function () {
      if (!/^\d{4,8}$/.test(f1.value)) { fehler.textContent = "Bitte 4 bis 8 Ziffern."; return; }
      if (f1.value !== f2.value) { fehler.textContent = "Die beiden Eingaben sind verschieden."; return; }
      ok.disabled = true; ok.textContent = "Wird gespeichert…";
      codeSpeichern(f1.value).then(function () { x.h.remove(); }, function () { ok.disabled = false; ok.textContent = "Speichern"; fehler.textContent = "Speichern klappt auf diesem Gerät nicht."; });
    };
    spaeter.onclick = function () { try { sessionStorage.setItem(SPAETER, "1"); } catch (e) { /* egal */ } x.h.remove(); };
    document.body.appendChild(x.h);
    setTimeout(function () { f1.focus(); }, 50);
  }

  pruefen(); // gleich beim Öffnen – bevor die App die Anmeldung liest
  document.addEventListener("DOMContentLoaded", codeAngebotPruefen);
  addEventListener("online", pruefen);
  addEventListener("offline", codeAngebotPruefen);
  addEventListener("storage", function (e) { if (e.key === SPERRE || e.key === CODES) pruefen(); });
  var zuletzt = 0;
  function aktiv() { if (ls(SPERRE)) return; var j = Date.now(); if (j - zuletzt > 5000) { zuletzt = j; ls(KEY, String(j)); } }
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
    keinAutoAbmelden: function (an) { var id = nutzerId(); ls(AUSNAHME, an && id ? id : null); if (!an) ls(KEY, String(Date.now())); },
    // Geräte-Code fürs Offline-Arbeiten festlegen/ändern (z. B. aus einem Einstellungs-Menü)
    offlineCodeFestlegen: codeFestlegen,
    gesperrt: function () { return !!ls(SPERRE); },
  };
})();
