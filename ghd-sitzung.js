// ============================================================
// GHD-SITZUNG — automatisch abmelden nach 15 Minuten ohne Bedienung
// Gilt für alle Great-Hair-Day-Apps unter derselben Adresse
// (mirjamwalenta-a11y.github.io): sie teilen sich Anmeldung und Speicher.
// Getippt in irgendeiner App = alle bleiben angemeldet; 15 Minuten nichts =
// überall abgemeldet, beim nächsten Öffnen wieder PIN.
// Einbinden im <head> VOR den App-Skripten:
//   <script src="https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-sitzung.js"></script>
// Ausnahme Stempel-Tablet: window.ghdSitzung.keinAutoAbmelden(true)
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
    ls(TOKEN, null); ls(KEY, null);
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
    if (!ls(TOKEN) && !eigeneAngemeldet()) return;
    if (ls(AUSNAHME) && ls(AUSNAHME) === nutzerId()) return; // angemeldet ist der Tablet-Zugang
    if (ls(AUSNAHME)) ls(AUSNAHME, null);                   // jemand anderer → Ausnahme gilt nicht mehr
    var letzte = +ls(KEY) || 0;
    if (!letzte) { ls(KEY, String(Date.now())); return; }
    if (Date.now() - letzte > MINUTEN * 60000) abmelden();
  }
  pruefen(); // gleich beim Öffnen – bevor die App die Anmeldung liest
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
    keinAutoAbmelden: function (an) { var id = nutzerId(); ls(AUSNAHME, an && id ? id : null); if (!an) ls(KEY, String(Date.now())); },
  };
})();
