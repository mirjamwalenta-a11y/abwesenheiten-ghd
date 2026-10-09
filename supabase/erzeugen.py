"""Erzeugt die Ausführungs-Skripte (Teil A/B/C) aus zeitverwaltung_schema_entwurf.sql.
Aufruf im Repo-Ordner:  python3 supabase/erzeugen.py
Der Entwurf bleibt die einzige Quelle – hier nichts von Hand ändern."""
import re, pathlib
R = pathlib.Path(__file__).resolve().parent.parent
src = (R / "zeitverwaltung_schema_entwurf.sql").read_text()
zeilen = src.split("\n")
def ab(marke): return [i for i, l in enumerate(zeilen) if marke in l][0] - 1
iB, iC = ab("URLAUBSSPERRE JE GRUPPE + NACHRICHTEN"), ab("SCHRITT 3 – ANBINDUNG DER APP")
teilA, teilB, teilC = "\n".join(zeilen[:iB]), "\n".join(zeilen[iB:iC]), "\n".join(zeilen[iC:])
# Teil C braucht die aktuelle Automatik-Funktion (offene Krankenstände) – aus Teil A übernehmen
m = re.search(r"DROP FUNCTION IF EXISTS zeit_automatik\(date, boolean, boolean, boolean\);.*?END \$\$;\n", teilA, re.S)
automatik = m.group(0)
kontrolle = """
-- ── Kontrolle: alle Tabellen der Zeitverwaltung haben RLS (Spalte rls muss überall true sein) ──
SELECT c.relname AS tabelle, c.relrowsecurity AS rls
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'zeit\\_%'
ORDER BY 1;
"""
pruefA = """DO $pruef$
BEGIN
  IF to_regclass('public.abw_team') IS NULL OR to_regclass('public.abw_anfragen') IS NULL THEN
    RAISE EXCEPTION 'Abbruch: abw_team / abw_anfragen nicht gefunden – ist das das richtige Supabase-Projekt?';
  END IF;
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'abw_team' AND column_name = 'id') <> 'text' THEN
    RAISE EXCEPTION 'Abbruch: abw_team.id ist nicht vom Typ text – bitte Claude Bescheid geben.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'abw_team' AND column_name = 'ausgeschieden_am') THEN
    RAISE EXCEPTION 'Abbruch: abw_team.ausgeschieden_am fehlt – zuerst ausgeschieden_mitarbeitende.sql ausführen.';
  END IF;
  IF to_regprocedure('public.abw_is_owner()') IS NULL OR to_regprocedure('public.abw_current_person_id()') IS NULL THEN
    RAISE EXCEPTION 'Abbruch: abw_is_owner() / abw_current_person_id() fehlen – zuerst rls_haertung_abwesenheit.sql ausführen.';
  END IF;
END $pruef$;
"""
kopf = lambda titel, text: f"""-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · {titel}
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
{text}
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
"""
A = kopf("SCHRITT 2 · TEIL A – Tabellen und Funktionen", "--  Ändert NICHTS am Verhalten der Abwesenheiten-App (nur neue Spalten\n--  an abw_anfragen und ein Protokoll-Trigger bei Austritten).") + "\n" + pruefA + "\n" + teilA + "\n\nCOMMIT;\n" + kontrolle
B = kopf("SCHRITT 2 · TEIL B – Urlaubssperre + Nachrichten", "--  ACHTUNG: wirkt auch in der Abwesenheiten-App (Trigger auf abw_anfragen).\n--  Erst NACH Teil A ausführen.\n--  Rückgängig: DROP TRIGGER zeit_urlaub_sperre ON abw_anfragen;\n--              DROP TRIGGER zeit_anfrage_nachricht ON abw_anfragen;") + "DO $pruef$ BEGIN\n  IF to_regclass('public.zeit_profil') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A ausführen.'; END IF;\nEND $pruef$;\n" + teilB + "\n\nCOMMIT;\n" + kontrolle
C = kopf("SCHRITT 3 · TEIL C – Anbindung der App", "--  Einstellungen an einer Stelle, Feiertage, Automatik-Job (pg_cron),\n--  Tablet-Liste mit Plan. Erst NACH Teil A und B ausführen.\n--  Vorher: Supabase → Database → Extensions → pg_cron aktivieren.") + "DO $pruef$ BEGIN\n  IF to_regclass('public.zeit_nachrichten') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A und Teil B ausführen.'; END IF;\nEND $pruef$;\n" + teilC.replace("ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende\n", "ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende\n\n" + automatik, 1) + "\n\nCOMMIT;\n" + kontrolle + """
-- ── Kontrolle: Automatik-Job eingerichtet? (eine Zeile „zeit-automatik“ = ja) ──
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'Automatik-Job eingerichtet (alle 15 Minuten)'
            ELSE 'Automatik-Job FEHLT – pg_cron aktivieren und Teil C nochmal ausführen' END AS automatik;
"""
for n, t in [("zeitverwaltung_schritt2_teilA.sql", A), ("zeitverwaltung_schritt2_teilB.sql", B), ("zeitverwaltung_schritt3_teilC.sql", C)]:
    (R / "supabase" / n).write_text(t)
print("ok")
