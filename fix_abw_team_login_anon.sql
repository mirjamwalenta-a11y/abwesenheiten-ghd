-- ════════════════════════════════════════════════════════════
--  Fix: "Wer bist du?"-Vorschau vor dem Login (abw_team_login)
--  war für anon (nicht angemeldete Nutzer:innen) nicht mehr lesbar.
--
--  Ursache: Die RLS-Härtung (rls_haertung_abwesenheit.sql) hat der
--  Rolle "anon" komplett den Zugriff auf die Tabelle abw_team entzogen
--  (absichtlich, wegen der PIN-Spalte). Übersehen wurde dabei, dass
--  die View abw_team_login (SELECT id, name, role FROM abw_team,
--  ohne WHERE) mit security_invoker läuft — sie braucht deshalb
--  selbst eine Freigabe auf abw_team, nicht nur eine Freigabe auf
--  die View. Die Namensauswahl VOR dem Login braucht das, weil man
--  da naturgemäß noch nicht angemeldet sein kann.
--
--  WICHTIG: Das ist NICHT dasselbe wie der Hinweis aus der
--  Fehlermeldung ("GRANT SELECT ON public.abw_team TO anon", ohne
--  Spaltenangabe) — das würde die komplette Tabelle inkl. PIN wieder
--  öffentlich lesbar machen. Hier werden bewusst nur die drei
--  Spalten freigegeben, die abw_team_login tatsächlich zeigt.
--
--  Im Supabase SQL-Editor ausführen. Bereits erfolgreich angewendet
--  (Live-Test am 2026-09-10) — Datei dient nur der Dokumentation.
-- ════════════════════════════════════════════════════════════

GRANT SELECT (id, name, role) ON public.abw_team TO anon;

DROP POLICY IF EXISTS "abw_team_anon_login_view" ON public.abw_team;
CREATE POLICY "abw_team_anon_login_view" ON public.abw_team
  FOR SELECT TO anon
  USING (true);
