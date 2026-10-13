// Service Worker dieser App: macht sie offline nutzbar.
// Die eigentliche Logik (Dateien merken, Supabase-Daten merken, Änderungen
// ohne Netz in einer Warteschlange sammeln und nachschicken, Konfliktregel
// „nichts überschreiben“) steckt zentral in ghd-offline-sw.js im Repo
// abwesenheiten-ghd und gilt für alle Great-Hair-Day-Apps gleich.
// Neue Seiten/Dateien dieser App hier bei `vorab` ergänzen.
self.GHD_OFFLINE = {
  app: 'abwesenheiten',
  version: '2026-10-13',
  start: './abwesenheiten.html',
  vorab: [
    './',
    './abwesenheiten.html',
    './zeitverwaltung.html',
    './stempel-qr.html',
    './icon-512.png',
    './manifest.json',
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js',
    'https://cdn.tailwindcss.com',
    'https://unpkg.com/@babel/standalone/babel.min.js',
    'https://unpkg.com/react-dom@18/umd/react-dom.production.min.js',
    'https://unpkg.com/react@18/umd/react.production.min.js',
    'https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/icon-512.png'
  ]
};
importScripts('https://mirjamwalenta-a11y.github.io/abwesenheiten-ghd/ghd-offline-sw.js');
