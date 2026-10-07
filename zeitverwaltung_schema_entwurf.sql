-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Zeitverwaltung
--  ENTWURF – NOCH NICHT IM LIVE-PROJEKT AUSFÜHREN.
--  Erst gemeinsam durchsehen (siehe ZEITVERWALTUNG.md, „Offene Fragen“),
--  dann im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar.
--
--  Setzt voraus: rls_haertung_abwesenheit.sql, rls_haertung_abw_team_spalten.sql,
--  ausgeschieden_mitarbeitende.sql (abw_team, abw_anfragen,
--  abw_is_owner(), abw_current_person_id()).
--
--  Grundsätze (CLAUDE.md):
--    * Jede neue Tabelle hat RLS ab dem Anlegen, anon bekommt nichts.
--    * Wer Chefin/Vorgesetzte/r ist, entscheidet die Datenbank – nie der Browser.
--    * Arbeitszeiten werden NICHT direkt per REST geschrieben, sondern nur über
--      SECURITY-DEFINER-Funktionen: Stempeln mit Serverzeit, jede Änderung
--      mit Pflicht-Grund und Protokoll, abgeschlossene Monate gesperrt.
--
--  Personen-Stammdaten bleiben in abw_team (eine zentrale Personenliste für
--  Abwesenheiten UND Zeiterfassung). Urlaub/Krankenstand bleiben in abw_anfragen.
-- ════════════════════════════════════════════════════════════

-- ── Arbeitszeitmodelle ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS zeit_arbeitsmodelle (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name      text NOT NULL,
  aktiv     boolean NOT NULL DEFAULT true
);
ALTER TABLE zeit_arbeitsmodelle ENABLE ROW LEVEL SECURITY;

-- Fixer Dienstplan: Beginn, Ende, Pause je Wochentag (0 = Montag … 6 = Sonntag).
-- Kein Eintrag = frei. Sollstunden = Ende − Beginn − Pause.
-- gueltig_ab: jede Änderung ist eine neue Version, vergangene Tage behalten ihren Plan.
CREATE TABLE IF NOT EXISTS zeit_modell_tage (
  modell_id  uuid NOT NULL REFERENCES zeit_arbeitsmodelle(id) ON DELETE CASCADE,
  gueltig_ab date NOT NULL DEFAULT '2000-01-01',
  wochentag  smallint NOT NULL CHECK (wochentag BETWEEN 0 AND 6),
  beginn     time NOT NULL,
  ende       time NOT NULL,
  pause_min  integer NOT NULL DEFAULT 0 CHECK (pause_min >= 0),
  PRIMARY KEY (modell_id, gueltig_ab, wochentag),
  CHECK (ende > beginn)
);
ALTER TABLE zeit_modell_tage ENABLE ROW LEVEL SECURITY;

-- Gesetzliche Feiertage (einmal pro Jahr befüllen; die App berechnet sie ohnehin)
CREATE TABLE IF NOT EXISTS zeit_feiertage (
  datum date PRIMARY KEY,
  name  text NOT NULL
);
ALTER TABLE zeit_feiertage ENABLE ROW LEVEL SECURITY;

-- ── Zeit-Profil je Person (Ergänzung zu abw_team) ──────────────
-- Rolle „Admin“ = abw_team.role = 'owner' (bestehend). Vorgesetzte ergeben
-- sich aus vorgesetzter_id: wer bei jemandem eingetragen ist, darf dort
-- genehmigen und korrigieren.
CREATE TABLE IF NOT EXISTS zeit_profil (
  person_id        text PRIMARY KEY REFERENCES abw_team(id),
  personalnr       text UNIQUE,
  abteilung        text,
  funktion         text,
  vorgesetzter_id  text REFERENCES abw_team(id),
  geburtsdatum     date,                             -- unter 18 → KJBG, ab dem 18. Geburtstag automatisch AZG
  lehrbeginn       date,                             -- nur Lehrlinge; Lehrjahr wird daraus berechnet
  bs_tag1          smallint CHECK (bs_tag1 BETWEEN 0 AND 6),  -- fixer Berufsschultag (ganz)
  bs_tag2          smallint CHECK (bs_tag2 BETWEEN 0 AND 6),  -- halber Tag im 1. Lehrjahr
  saldo_start_min  integer NOT NULL DEFAULT 0,       -- Übertrag Zeitkonto beim Start
  urlaub_uebertrag numeric(4,1) NOT NULL DEFAULT 0,
  CHECK (vorgesetzter_id IS NULL OR vorgesetzter_id <> person_id)
);
ALTER TABLE zeit_profil ENABLE ROW LEVEL SECURITY;

-- Modell-Zuordnung mit „gültig ab“, damit Modellwechsel alte Monate nicht verändern
CREATE TABLE IF NOT EXISTS zeit_modell_zuordnung (
  person_id  text NOT NULL REFERENCES abw_team(id),
  gueltig_ab date NOT NULL,
  modell_id  uuid NOT NULL REFERENCES zeit_arbeitsmodelle(id),
  PRIMARY KEY (person_id, gueltig_ab)
);
ALTER TABLE zeit_modell_zuordnung ENABLE ROW LEVEL SECURITY;

-- ── Arbeitszeit-Buchungen (eine pro Person und Tag) ────────────
CREATE TABLE IF NOT EXISTS zeit_buchungen (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id    text NOT NULL REFERENCES abw_team(id),
  datum        date NOT NULL,
  beginn       time NOT NULL,
  ende         time,
  pause_min    integer NOT NULL DEFAULT 0 CHECK (pause_min >= 0),
  pause_start  time,
  quelle       text NOT NULL DEFAULT 'stempel' CHECK (quelle IN ('stempel', 'manuell', 'korrektur', 'auto')),
  auto         text[] NOT NULL DEFAULT '{}',   -- was laut Dienstplan ergänzt wurde: kommen/gehen/pause/tag
  notiz        text,
  erstellt_am  timestamptz NOT NULL DEFAULT now(),
  geaendert_am timestamptz,
  UNIQUE (person_id, datum),
  CHECK (ende IS NULL OR ende >= beginn)
);
ALTER TABLE zeit_buchungen ENABLE ROW LEVEL SECURITY;

-- ── Korrekturanträge von Mitarbeiter/innen ─────────────────────
CREATE TABLE IF NOT EXISTS zeit_korrekturen (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id       text NOT NULL REFERENCES abw_team(id),
  datum           date NOT NULL,
  neu_beginn      time,            -- alle drei NULL = Eintrag löschen
  neu_ende        time,
  neu_pause_min   integer,
  grund           text NOT NULL CHECK (length(trim(grund)) > 0),
  status          text NOT NULL DEFAULT 'offen' CHECK (status IN ('offen', 'genehmigt', 'abgelehnt')),
  beantragt_von   text NOT NULL REFERENCES abw_team(id),
  beantragt_am    timestamptz NOT NULL DEFAULT now(),
  entschieden_von text REFERENCES abw_team(id),
  entschieden_am  timestamptz
);
ALTER TABLE zeit_korrekturen ENABLE ROW LEVEL SECURITY;

-- ── Änderungsprotokoll (nur lesbar, geschrieben nur von Funktionen) ─
CREATE TABLE IF NOT EXISTS zeit_protokoll (
  id         bigserial PRIMARY KEY,
  am         timestamptz NOT NULL DEFAULT now(),
  von_person text,
  person_id  text NOT NULL,
  datum      date NOT NULL,
  aktion     text NOT NULL,
  alt        jsonb,
  neu        jsonb,
  grund      text
);
ALTER TABLE zeit_protokoll ENABLE ROW LEVEL SECURITY;

-- ── Monatsabschluss ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS zeit_monatsabschluss (
  person_id        text NOT NULL REFERENCES abw_team(id),
  monat            date NOT NULL CHECK (extract(day FROM monat) = 1),
  bestaetigt_am    timestamptz,
  abgeschlossen_am timestamptz,
  abgeschlossen_von text REFERENCES abw_team(id),
  PRIMARY KEY (person_id, monat)
);
ALTER TABLE zeit_monatsabschluss ENABLE ROW LEVEL SECURITY;

-- ── Ergänzungen an abw_anfragen (Krankenstand/Abwesenheiten) ───
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS au_bestaetigung boolean;
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS notiz text;
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS entschieden_von text REFERENCES abw_team(id);
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS entschieden_am timestamptz;
-- Halbe Tage (z. B. halber Berufsschultag im 1. Lehrjahr): 1 = ganzer Tag
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS anteil numeric(3,2) NOT NULL DEFAULT 1;
ALTER TABLE abw_anfragen DROP CONSTRAINT IF EXISTS abw_anfragen_anteil_check;
ALTER TABLE abw_anfragen ADD CONSTRAINT abw_anfragen_anteil_check CHECK (anteil IN (0.5, 1));
-- Berufsschultage je Lehrjahr kommen in die bestehende abw_einstellungen,
-- Schlüssel 'bs_tage_je_lehrjahr', z. B. {"1":1.5,"2":1,"3":1,"4":1} (Wien).

-- Nicht-anonym, sonst nichts: anon hat auf keiner Zeit-Tabelle etwas verloren
REVOKE ALL ON zeit_arbeitsmodelle, zeit_modell_tage, zeit_feiertage, zeit_profil, zeit_modell_zuordnung, zeit_buchungen,
              zeit_korrekturen, zeit_protokoll, zeit_monatsabschluss FROM anon;

-- ════════════════════════════════════════════════════════════
--  Hilfsfunktionen (Rollen kommen aus der Datenbank, nicht vom Client)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_ist_vorgesetzt_von(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM zeit_profil
    WHERE person_id = p_person
      AND vorgesetzter_id = abw_current_person_id()
      AND person_id <> abw_current_person_id()
  );
$$;

-- Genehmigen/Korrigieren: Chefin bei allen (auch bei sich), Vorgesetzte nur bei Unterstellten
CREATE OR REPLACE FUNCTION zeit_darf_verwalten(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT abw_is_owner() OR zeit_ist_vorgesetzt_von(p_person);
$$;

CREATE OR REPLACE FUNCTION zeit_darf_sehen(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_person = abw_current_person_id() OR zeit_darf_verwalten(p_person);
$$;

CREATE OR REPLACE FUNCTION zeit_monat_gesperrt(p_person text, p_datum date) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM zeit_monatsabschluss
    WHERE person_id = p_person
      AND monat = date_trunc('month', p_datum)::date
      AND abgeschlossen_am IS NOT NULL
  );
$$;

-- Dienstplan einer Person an einem Tag (gültige Modellzuordnung zu diesem Datum)
CREATE OR REPLACE FUNCTION zeit_plan_am(p_person text, p_datum date) RETURNS zeit_modell_tage
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT t.* FROM zeit_modell_zuordnung z
  JOIN zeit_modell_tage t ON t.modell_id = z.modell_id AND t.wochentag = extract(isodow FROM p_datum)::int - 1
   AND t.gueltig_ab = (SELECT max(gueltig_ab) FROM zeit_modell_tage WHERE modell_id = z.modell_id AND gueltig_ab <= p_datum)
  WHERE z.person_id = p_person AND z.gueltig_ab <= p_datum
    AND z.gueltig_ab = (SELECT max(gueltig_ab) FROM zeit_modell_zuordnung WHERE person_id = p_person AND gueltig_ab <= p_datum);
$$;

CREATE OR REPLACE FUNCTION zeit_jugendlich(p_person text, p_datum date) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT geburtsdatum + interval '18 years' > p_datum FROM zeit_profil WHERE person_id = p_person), false);
$$;

-- Wird nachträglich eine Pause gebraucht? (§ 11 AZG: > 6 h; § 15 KJBG: > 4,5 h → 30 min)
CREATE OR REPLACE FUNCTION zeit_pause_noetig(p_person text, b zeit_buchungen) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.ende IS NOT NULL AND b.pause_min < 30
     AND extract(epoch FROM b.ende - b.beginn) / 60 - b.pause_min
         > CASE WHEN zeit_jugendlich(p_person, b.datum) THEN 270 ELSE 360 END;
$$;

-- ════════════════════════════════════════════════════════════
--  RLS-Policies
-- ════════════════════════════════════════════════════════════
-- Modelle: alle Angemeldeten lesen, nur Chefin ändert
DROP POLICY IF EXISTS "zeit_modelle_select" ON zeit_arbeitsmodelle;
CREATE POLICY "zeit_modelle_select" ON zeit_arbeitsmodelle FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_modelle_write" ON zeit_arbeitsmodelle;
CREATE POLICY "zeit_modelle_write" ON zeit_arbeitsmodelle FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "zeit_modell_tage_select" ON zeit_modell_tage;
CREATE POLICY "zeit_modell_tage_select" ON zeit_modell_tage FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_modell_tage_write" ON zeit_modell_tage;
CREATE POLICY "zeit_modell_tage_write" ON zeit_modell_tage FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());
DROP POLICY IF EXISTS "zeit_feiertage_select" ON zeit_feiertage;
CREATE POLICY "zeit_feiertage_select" ON zeit_feiertage FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_feiertage_write" ON zeit_feiertage;
CREATE POLICY "zeit_feiertage_write" ON zeit_feiertage FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

-- Profil & Modellzuordnung: eigene + verwaltete lesen, nur Chefin ändert
DROP POLICY IF EXISTS "zeit_profil_select" ON zeit_profil;
CREATE POLICY "zeit_profil_select" ON zeit_profil FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_profil_write" ON zeit_profil;
CREATE POLICY "zeit_profil_write" ON zeit_profil FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "zeit_zuordnung_select" ON zeit_modell_zuordnung;
CREATE POLICY "zeit_zuordnung_select" ON zeit_modell_zuordnung FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_zuordnung_write" ON zeit_modell_zuordnung;
CREATE POLICY "zeit_zuordnung_write" ON zeit_modell_zuordnung FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

-- Buchungen, Protokoll, Abschlüsse: nur lesen. Geschrieben wird ausschließlich
-- über die Funktionen unten (keine INSERT/UPDATE/DELETE-Policy = verboten).
DROP POLICY IF EXISTS "zeit_buchungen_select" ON zeit_buchungen;
CREATE POLICY "zeit_buchungen_select" ON zeit_buchungen FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_protokoll_select" ON zeit_protokoll;
CREATE POLICY "zeit_protokoll_select" ON zeit_protokoll FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_abschluss_select" ON zeit_monatsabschluss;
CREATE POLICY "zeit_abschluss_select" ON zeit_monatsabschluss FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));

-- Korrekturanträge: lesen wie Buchungen; anlegen nur für sich selbst, als „offen“,
-- und nicht in abgeschlossenen Monaten. Entscheiden nur per Funktion.
DROP POLICY IF EXISTS "zeit_korrekturen_select" ON zeit_korrekturen;
CREATE POLICY "zeit_korrekturen_select" ON zeit_korrekturen FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_korrekturen_insert" ON zeit_korrekturen;
CREATE POLICY "zeit_korrekturen_insert" ON zeit_korrekturen FOR INSERT TO authenticated
  WITH CHECK (
    person_id = abw_current_person_id()
    AND beantragt_von = abw_current_person_id()
    AND status = 'offen'
    AND entschieden_von IS NULL
    AND datum <= (now() AT TIME ZONE 'Europe/Vienna')::date
    AND NOT zeit_monat_gesperrt(person_id, datum)
  );

-- ════════════════════════════════════════════════════════════
--  Sicherheitsnetz: abgeschlossene Monate sind auch für Funktionen tabu
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_buchungen_sperre() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP <> 'INSERT' AND zeit_monat_gesperrt(OLD.person_id, OLD.datum) THEN
    RAISE EXCEPTION 'Monat % ist abgeschlossen', to_char(OLD.datum, 'MM/YYYY');
  END IF;
  IF TG_OP <> 'DELETE' AND zeit_monat_gesperrt(NEW.person_id, NEW.datum) THEN
    RAISE EXCEPTION 'Monat % ist abgeschlossen', to_char(NEW.datum, 'MM/YYYY');
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS zeit_buchungen_sperre ON zeit_buchungen;
CREATE TRIGGER zeit_buchungen_sperre BEFORE INSERT OR UPDATE OR DELETE ON zeit_buchungen
  FOR EACH ROW EXECUTE FUNCTION zeit_buchungen_sperre();

-- ════════════════════════════════════════════════════════════
--  Funktionen (RPC) – der einzige Schreibweg für Arbeitszeiten
-- ════════════════════════════════════════════════════════════

-- Automatische Pausen nur mit schriftlicher Pausen-Vereinbarung je Person
-- (§ 26 Abs 5 AZG). Derzeit gibt es nur den Kollektivvertrag → AUS.
-- Sobald die Vereinbarungen unterschrieben sind: Funktion auf "SELECT true" ändern.
CREATE OR REPLACE FUNCTION zeit_auto_pause_erlaubt() RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT false $$;

-- Stempel-Logik für eine Person. INTERN – nicht für Benutzer freigegeben;
-- aufgerufen von zeit_stempeln (Handy) und zeit_terminal_stempeln (Tablet).
-- Uhrzeit immer vom Server (Europe/Vienna).
-- p_aktion: 'kommen' | 'pause_start' | 'pause_ende' | 'gehen' | 'nur_gehen' (Kommen vergessen)
-- p_auto_pause: fehlende Pause beim Gehen laut Dienstplan eintragen
CREATE OR REPLACE FUNCTION zeit__stempeln_fuer(p_person text, p_aktion text, p_auto_pause boolean) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_person text := p_person;
  v_jetzt  timestamp := now() AT TIME ZONE 'Europe/Vienna';
  v_datum  date := v_jetzt::date;
  v_zeit   time := date_trunc('minute', v_jetzt)::time;
  b        zeit_buchungen;
  v_plan   zeit_modell_tage;
BEGIN
  IF v_person IS NULL THEN RAISE EXCEPTION 'Keine Person'; END IF;
  v_plan := zeit_plan_am(v_person, v_datum);
  SELECT * INTO b FROM zeit_buchungen WHERE person_id = v_person AND datum = v_datum FOR UPDATE;
  IF p_aktion = 'nur_gehen' THEN
    IF FOUND THEN RAISE EXCEPTION 'Heute bereits eingestempelt'; END IF;
    IF v_plan.beginn IS NULL OR v_plan.beginn >= v_zeit THEN RAISE EXCEPTION 'Kein Dienstplan-Beginn vor jetzt'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, quelle, auto)
      VALUES (v_person, v_datum, v_plan.beginn, 'stempel', ARRAY['kommen']) RETURNING * INTO b;
    INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
      VALUES (abw_current_person_id(), v_person, v_datum, 'automatisch ergänzt: Kommen', 'Kommen vergessen – Beginn laut Dienstplan');
    p_aktion := 'gehen';
  END IF;
  IF p_aktion = 'kommen' THEN
    IF FOUND THEN RAISE EXCEPTION 'Heute bereits eingestempelt'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, quelle)
      VALUES (v_person, v_datum, v_zeit, 'stempel') RETURNING * INTO b;
  ELSIF NOT FOUND OR b.ende IS NOT NULL THEN
    RAISE EXCEPTION 'Kein laufender Dienst';
  ELSIF p_aktion = 'pause_start' THEN
    IF b.pause_start IS NOT NULL THEN RAISE EXCEPTION 'Pause läuft bereits'; END IF;
    UPDATE zeit_buchungen SET pause_start = v_zeit WHERE id = b.id RETURNING * INTO b;
  ELSIF p_aktion = 'pause_ende' THEN
    IF b.pause_start IS NULL THEN RAISE EXCEPTION 'Keine laufende Pause'; END IF;
    UPDATE zeit_buchungen
      SET pause_min = pause_min + (extract(epoch FROM v_zeit - pause_start) / 60)::int, pause_start = NULL
      WHERE id = b.id RETURNING * INTO b;
  ELSIF p_aktion = 'gehen' THEN
    UPDATE zeit_buchungen
      SET pause_min = pause_min + COALESCE((extract(epoch FROM v_zeit - pause_start) / 60)::int, 0),
          pause_start = NULL, ende = v_zeit
      WHERE id = b.id RETURNING * INTO b;
    IF p_auto_pause AND zeit_auto_pause_erlaubt() AND zeit_pause_noetig(v_person, b) THEN
      UPDATE zeit_buchungen SET pause_min = greatest(COALESCE(v_plan.pause_min, 0), 30), auto = auto || 'pause'::text
        WHERE id = b.id RETURNING * INTO b;
      INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
        VALUES (abw_current_person_id(), v_person, v_datum, 'automatisch ergänzt: Pause', 'keine Pause gestempelt – laut Dienstplan');
    END IF;
  ELSE
    RAISE EXCEPTION 'Unbekannte Aktion: %', p_aktion;
  END IF;
  RETURN b;
END $$;

-- HANDY: Person kommt aus dem eigenen Login
DROP FUNCTION IF EXISTS zeit_stempeln(text);
CREATE OR REPLACE FUNCTION zeit_stempeln(p_aktion text, p_auto_pause boolean DEFAULT true) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF abw_current_person_id() IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  RETURN zeit__stempeln_fuer(abw_current_person_id(), p_aktion, p_auto_pause);
END $$;

-- ════════════════════════════════════════════════════════════
--  STEMPEL-TABLET IM SALON
--  * Das Tablet meldet sich EINMAL mit einem eigenen Gerätezugang an
--    (Supabase Auth, z. B. terminal.salon@…; Passwort nur die Chefin).
--    Die Sitzung bleibt per Supabase-Refresh-Token bestehen (CLAUDE.md Regel 4).
--  * Nur in zeit_terminals eingetragene Gerätezugänge dürfen Tablet-Funktionen
--    nutzen. Ein Mitarbeiter-Handy kann also NICHT für andere stempeln.
--  * Jede Person bestätigt mit ihrer persönlichen PIN – derselben wie beim
--    Login der Abwesenheiten-App. Geprüft wird nur hier am Server gegen den
--    Passwort-Hash in auth.users; die PIN wird nirgends gespeichert.
--  * Nach 5 falschen PINs in 15 Minuten ist die Person 15 Minuten gesperrt.
-- ════════════════════════════════════════════════════════════
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS zeit_terminals (
  user_id     uuid PRIMARY KEY,          -- auth.users.id des Tablet-Zugangs
  name        text NOT NULL,             -- z. B. 'Tablet Empfang'
  aktiv       boolean NOT NULL DEFAULT true,
  angelegt_am timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE zeit_terminals ENABLE ROW LEVEL SECURITY;   -- keine Policy: nur per SQL/Funktion

CREATE TABLE IF NOT EXISTS zeit_pin_versuche (
  id        bigserial PRIMARY KEY,
  person_id text NOT NULL,
  am        timestamptz NOT NULL DEFAULT now(),
  ok        boolean NOT NULL
);
ALTER TABLE zeit_pin_versuche ENABLE ROW LEVEL SECURITY; -- keine Policy
REVOKE ALL ON zeit_terminals, zeit_pin_versuche FROM anon, authenticated;

CREATE OR REPLACE FUNCTION zeit_ist_terminal() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM zeit_terminals WHERE user_id = auth.uid() AND aktiv);
$$;

-- Liste fürs Tablet: nur Vorname und heutiger Stempel-Status, keine sonstigen Daten
CREATE OR REPLACE FUNCTION zeit_terminal_liste()
RETURNS TABLE (person_id text, vorname text, status text, seit time)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT zeit_ist_terminal() THEN RAISE EXCEPTION 'Kein Stempel-Tablet'; END IF;
  RETURN QUERY
    SELECT t.id, split_part(trim(t.name), ' ', 1),
           CASE WHEN b.id IS NULL THEN 'aus' WHEN b.ende IS NOT NULL THEN 'fertig'
                WHEN b.pause_start IS NOT NULL THEN 'pause' ELSE 'da' END,
           COALESCE(b.pause_start, b.beginn)
    FROM abw_team t
    LEFT JOIN zeit_buchungen b ON b.person_id = t.id AND b.datum = (now() AT TIME ZONE 'Europe/Vienna')::date
    WHERE t.ausgeschieden_am IS NULL
    ORDER BY t.name;
END $$;

-- PIN gegen den Login-Hash prüfen (Login-Passwort = PIN + '-ghd', siehe abwesenheiten.html)
CREATE OR REPLACE FUNCTION zeit__pin_ok(p_person text, p_pin text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_hash text;
BEGIN
  SELECT u.encrypted_password INTO v_hash
  FROM abw_team t JOIN auth.users u
    ON u.email = lower(replace(trim(t.name), ' ', '.')) || '.abwesenheit@greathairday.at'
  WHERE t.id = p_person AND t.ausgeschieden_am IS NULL;
  RETURN v_hash IS NOT NULL AND p_pin ~ '^[0-9]{4}$' AND v_hash = crypt(p_pin || '-ghd', v_hash);
END $$;

-- Stempeln am Tablet. Gibt bei falscher PIN {ok:false} zurück statt einen Fehler zu
-- werfen – sonst würde der Fehlversuch mit zurückgerollt und die Sperre wirkte nicht.
CREATE OR REPLACE FUNCTION zeit_terminal_stempeln(p_person text, p_pin text, p_aktion text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b zeit_buchungen;
BEGIN
  IF NOT zeit_ist_terminal() THEN RAISE EXCEPTION 'Kein Stempel-Tablet'; END IF;
  IF (SELECT count(*) FROM zeit_pin_versuche
      WHERE person_id = p_person AND NOT ok AND am > now() - interval '15 minutes') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'fehler', 'Zu viele falsche PINs – bitte 15 Minuten warten');
  END IF;
  IF NOT zeit__pin_ok(p_person, p_pin) THEN
    INSERT INTO zeit_pin_versuche (person_id, ok) VALUES (p_person, false);
    RETURN jsonb_build_object('ok', false, 'fehler', 'PIN falsch');
  END IF;
  INSERT INTO zeit_pin_versuche (person_id, ok) VALUES (p_person, true);
  b := zeit__stempeln_fuer(p_person, p_aktion, true);
  RETURN jsonb_build_object('ok', true, 'beginn', b.beginn, 'ende', b.ende, 'pause_min', b.pause_min, 'auto', b.auto);
END $$;

REVOKE ALL ON FUNCTION zeit__stempeln_fuer(text, text, boolean), zeit__pin_ok(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION zeit_ist_terminal(), zeit_terminal_liste(), zeit_terminal_stempeln(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_ist_terminal(), zeit_terminal_liste(), zeit_terminal_stempeln(text, text, text) TO authenticated;
-- Tablet registrieren (einmalig, nachdem der Gerätezugang in Supabase Auth angelegt wurde):
-- INSERT INTO zeit_terminals (user_id, name) SELECT id, 'Tablet Empfang' FROM auth.users WHERE email = '<Tablet-Zugang>';

-- Direkte Änderung durch Chefin/Vorgesetzte – immer mit Grund, immer protokolliert
CREATE OR REPLACE FUNCTION zeit_buchung_aendern(
  p_person text, p_datum date, p_beginn time, p_ende time, p_pause_min integer,
  p_grund text, p_loeschen boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_alt   zeit_buchungen;
  v_gab   boolean;
BEGIN
  IF NOT zeit_darf_verwalten(p_person) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF COALESCE(trim(p_grund), '') = '' THEN RAISE EXCEPTION 'Grund fehlt'; END IF;
  IF p_datum > (now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Datum liegt in der Zukunft'; END IF;
  SELECT * INTO v_alt FROM zeit_buchungen WHERE person_id = p_person AND datum = p_datum FOR UPDATE;
  v_gab := FOUND;
  IF p_loeschen THEN
    IF NOT v_gab THEN RAISE EXCEPTION 'Kein Eintrag vorhanden'; END IF;
    DELETE FROM zeit_buchungen WHERE id = v_alt.id;
  ELSE
    IF p_beginn IS NULL OR p_ende IS NULL OR p_ende <= p_beginn THEN RAISE EXCEPTION 'Beginn/Ende ungültig'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, ende, pause_min, quelle)
      VALUES (p_person, p_datum, p_beginn, p_ende, COALESCE(p_pause_min, 0), 'manuell')
    ON CONFLICT (person_id, datum) DO UPDATE
      SET beginn = EXCLUDED.beginn, ende = EXCLUDED.ende, pause_min = EXCLUDED.pause_min,
          pause_start = NULL, quelle = 'korrektur', auto = '{}', geaendert_am = now();
  END IF;
  INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, alt, neu, grund)
  VALUES (
    abw_current_person_id(), p_person, p_datum,
    CASE WHEN p_loeschen THEN 'gelöscht' WHEN v_gab THEN 'korrigiert' ELSE 'nachgetragen' END,
    CASE WHEN v_gab THEN jsonb_build_object('beginn', v_alt.beginn, 'ende', v_alt.ende, 'pause_min', v_alt.pause_min) END,
    CASE WHEN NOT p_loeschen THEN jsonb_build_object('beginn', p_beginn, 'ende', p_ende, 'pause_min', COALESCE(p_pause_min, 0)) END,
    p_grund
  );
END $$;

CREATE OR REPLACE FUNCTION zeit_korrektur_entscheiden(p_id uuid, p_genehmigt boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE k zeit_korrekturen;
BEGIN
  SELECT * INTO k FROM zeit_korrekturen WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR k.status <> 'offen' THEN RAISE EXCEPTION 'Antrag nicht (mehr) offen'; END IF;
  IF NOT zeit_darf_verwalten(k.person_id) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF p_genehmigt THEN
    PERFORM zeit_buchung_aendern(k.person_id, k.datum, k.neu_beginn, k.neu_ende, k.neu_pause_min,
                                 'Korrekturantrag: ' || k.grund, k.neu_beginn IS NULL);
  END IF;
  UPDATE zeit_korrekturen
    SET status = CASE WHEN p_genehmigt THEN 'genehmigt' ELSE 'abgelehnt' END,
        entschieden_von = abw_current_person_id(), entschieden_am = now()
    WHERE id = p_id;
END $$;

-- Mitarbeiter/in bestätigt einen vergangenen Monat
CREATE OR REPLACE FUNCTION zeit_monat_bestaetigen(p_monat date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_person text := abw_current_person_id(); v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF v_person IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  IF v_monat >= date_trunc('month', now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Monat ist noch nicht vorbei'; END IF;
  INSERT INTO zeit_monatsabschluss (person_id, monat, bestaetigt_am) VALUES (v_person, v_monat, now())
  ON CONFLICT (person_id, monat) DO UPDATE SET bestaetigt_am = now()
    WHERE zeit_monatsabschluss.abgeschlossen_am IS NULL;
END $$;

-- Chefin/Vorgesetzte schließt ab → Monat gesperrt
CREATE OR REPLACE FUNCTION zeit_monat_abschliessen(p_person text, p_monat date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF NOT zeit_darf_verwalten(p_person) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF v_monat >= date_trunc('month', now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Monat ist noch nicht vorbei'; END IF;
  IF EXISTS (SELECT 1 FROM zeit_korrekturen WHERE person_id = p_person AND status = 'offen'
             AND date_trunc('month', datum)::date = v_monat) THEN
    RAISE EXCEPTION 'Es gibt offene Korrekturanträge';
  END IF;
  IF EXISTS (SELECT 1 FROM zeit_buchungen WHERE person_id = p_person AND ende IS NULL
             AND date_trunc('month', datum)::date = v_monat) THEN
    RAISE EXCEPTION 'Ein Tag hat noch kein Arbeitsende';
  END IF;
  INSERT INTO zeit_monatsabschluss (person_id, monat, abgeschlossen_am, abgeschlossen_von)
    VALUES (p_person, v_monat, now(), abw_current_person_id())
  ON CONFLICT (person_id, monat) DO UPDATE
    SET abgeschlossen_am = now(), abgeschlossen_von = abw_current_person_id();
END $$;

-- Nur die Chefin darf wieder öffnen – mit Grund im Protokoll
CREATE OR REPLACE FUNCTION zeit_monat_oeffnen(p_person text, p_monat date, p_grund text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF COALESCE(trim(p_grund), '') = '' THEN RAISE EXCEPTION 'Grund fehlt'; END IF;
  UPDATE zeit_monatsabschluss SET abgeschlossen_am = NULL, abgeschlossen_von = NULL
    WHERE person_id = p_person AND monat = v_monat;
  INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
    VALUES (abw_current_person_id(), p_person, v_monat, 'Monat wieder geöffnet', p_grund);
END $$;

-- ════════════════════════════════════════════════════════════
--  Nächtliche Automatik (fixer Dienstplan): ergänzt den Vortag
--  * vergessenes Gehen → Dienstende laut Plan
--  * fehlende Pause    → Pause laut Plan (mind. 30 min)
--  * gar nicht gestempelt (und keine Abwesenheit) → ganzer Tag laut Plan
--  Läuft NICHT als Benutzer, sondern per pg_cron. Jede Ergänzung ist in
--  zeit_buchungen.auto markiert und steht im Protokoll.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_automatik(
  p_datum date DEFAULT ((now() AT TIME ZONE 'Europe/Vienna')::date - 1),
  p_auto_gehen boolean DEFAULT true, p_auto_pause boolean DEFAULT true, p_auto_fehltag boolean DEFAULT true
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p      record;
  v_plan zeit_modell_tage;
  b      zeit_buchungen;
  n      integer := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM zeit_feiertage WHERE datum = p_datum) THEN RETURN 0; END IF;
  FOR p IN SELECT id FROM abw_team WHERE ausgeschieden_am IS NULL OR ausgeschieden_am >= p_datum LOOP
    v_plan := zeit_plan_am(p.id, p_datum);
    CONTINUE WHEN v_plan.beginn IS NULL OR zeit_monat_gesperrt(p.id, p_datum);
    SELECT * INTO b FROM zeit_buchungen WHERE person_id = p.id AND datum = p_datum FOR UPDATE;
    IF NOT FOUND THEN
      -- jede genehmigte Abwesenheit (auch halbe Tage) → nichts automatisch anlegen
      CONTINUE WHEN NOT p_auto_fehltag OR EXISTS (
        SELECT 1 FROM abw_anfragen WHERE person_id = p.id AND status = 'genehmigt' AND p_datum BETWEEN von AND bis);
      INSERT INTO zeit_buchungen (person_id, datum, beginn, ende, pause_min, quelle, auto)
        VALUES (p.id, p_datum, v_plan.beginn, v_plan.ende, v_plan.pause_min, 'auto', ARRAY['tag']);
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: ganzer Tag', 'nicht gestempelt – laut Dienstplan');
      n := n + 1;
      CONTINUE;
    END IF;
    IF b.ende IS NULL AND p_auto_gehen THEN
      UPDATE zeit_buchungen
        SET ende = greatest(v_plan.ende, beginn),
            pause_min = pause_min + COALESCE((extract(epoch FROM greatest(v_plan.ende, beginn) - pause_start) / 60)::int, 0),
            pause_start = NULL, auto = auto || 'gehen'::text
        WHERE id = b.id RETURNING * INTO b;
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: Gehen', 'nicht ausgestempelt – Dienstende laut Plan');
      n := n + 1;
    END IF;
    IF p_auto_pause AND zeit_auto_pause_erlaubt() AND zeit_pause_noetig(p.id, b) THEN
      UPDATE zeit_buchungen SET pause_min = greatest(v_plan.pause_min, 30), auto = auto || 'pause'::text WHERE id = b.id;
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: Pause', 'keine Pause gestempelt – laut Dienstplan');
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;
-- Nur der Server-Job darf das ausführen, kein Benutzer:
REVOKE ALL ON FUNCTION zeit_automatik(date, boolean, boolean, boolean) FROM PUBLIC, anon, authenticated;
-- Einrichten (Supabase → Database → Extensions → pg_cron aktivieren), täglich 02:15 UTC:
-- SELECT cron.schedule('zeit-automatik', '15 2 * * *', $cron$ SELECT zeit_automatik(); $cron$);

-- Funktionen: nur für Angemeldete (Supabase gibt sonst auch anon EXECUTE)
REVOKE ALL ON FUNCTION zeit_stempeln(text, boolean), zeit_plan_am(text, date), zeit_jugendlich(text, date),
  zeit_pause_noetig(text, zeit_buchungen), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
  zeit_korrektur_entscheiden(uuid, boolean), zeit_monat_bestaetigen(date),
  zeit_monat_abschliessen(text, date), zeit_monat_oeffnen(text, date, text),
  zeit_ist_vorgesetzt_von(text), zeit_darf_verwalten(text), zeit_darf_sehen(text),
  zeit_monat_gesperrt(text, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_stempeln(text, boolean), zeit_plan_am(text, date), zeit_jugendlich(text, date),
  zeit_pause_noetig(text, zeit_buchungen), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
  zeit_korrektur_entscheiden(uuid, boolean), zeit_monat_bestaetigen(date),
  zeit_monat_abschliessen(text, date), zeit_monat_oeffnen(text, date, text),
  zeit_ist_vorgesetzt_von(text), zeit_darf_verwalten(text), zeit_darf_sehen(text),
  zeit_monat_gesperrt(text, date)
  TO authenticated;

-- ════════════════════════════════════════════════════════════
--  OPTIONAL, ERST NACH RÜCKSPRACHE: Vorgesetzte dürfen Urlaub/Abwesenheiten
--  ihres Teams genehmigen. Ändert eine LIVE-Policy der Abwesenheiten-App
--  (bisher: nur Chefin). Darum auskommentiert.
-- ════════════════════════════════════════════════════════════
-- DROP POLICY IF EXISTS "abw_anfragen_update" ON abw_anfragen;
-- CREATE POLICY "abw_anfragen_update" ON abw_anfragen FOR UPDATE TO authenticated
--   USING (abw_is_owner() OR zeit_ist_vorgesetzt_von(person_id))
--   WITH CHECK (abw_is_owner() OR zeit_ist_vorgesetzt_von(person_id));
