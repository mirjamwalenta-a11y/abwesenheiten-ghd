-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Abwesenheiten
--  Login-Konto automatisch anlegen / PIN ändern
--
--  Problem: Der Login prüft die PIN nicht in abw_team, sondern meldet
--  sich bei Supabase Auth an (E-Mail <name>.abwesenheit@greathairday.at,
--  Passwort <PIN>-ghd, siehe abwEmail()/Login in abwesenheiten.html).
--  Bisher schrieb die App beim Anlegen einer Mitarbeiterin und beim
--  PIN-Ändern nur in abw_team — das Supabase-Konto musste von Hand im
--  Dashboard angelegt bzw. geändert werden, sonst hieß es "Falscher PIN".
--
--  Lösung: abw_login_setzen(person, pin) legt das Konto an oder setzt
--  das Passwort neu. Die Rollenprüfung passiert hier am Server
--  (abw_is_owner(), CLAUDE.md Regel 3) — nur die Chefin darf das.
--  Die Funktion kann ausschließlich Konten nach dem Muster
--  *.abwesenheit@greathairday.at anfassen, keine anderen Supabase-Konten.
--
--  Im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar.
--  Voraussetzung: rls_haertung_abwesenheit.sql (abw_is_owner()).
-- ════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Login-E-Mail wie abwEmail() im Frontend (Leerzeichen → Punkt, klein geschrieben)
CREATE OR REPLACE FUNCTION abw__login_email(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(regexp_replace(trim(p_name), '\s+', '.', 'g')) || '.abwesenheit@greathairday.at';
$$;

-- Konto anlegen oder Passwort setzen — ohne Rollenprüfung, nur intern verwendet
CREATE OR REPLACE FUNCTION abw__login_schreiben(p_email text, p_pin text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id uuid;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'PIN muss 4 Ziffern haben.'; END IF;

  SELECT id INTO v_id FROM auth.users WHERE lower(email) = p_email;
  IF v_id IS NOT NULL THEN
    UPDATE auth.users
       SET encrypted_password = crypt(p_pin || '-ghd', gen_salt('bf')),
           email_confirmed_at = COALESCE(email_confirmed_at, now()),
           updated_at = now()
     WHERE id = v_id;
    RETURN;
  END IF;

  v_id := gen_random_uuid();
  -- Die Token-Spalten müssen '' statt NULL sein, sonst scheitert der Login in Supabase Auth.
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  VALUES ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email,
          crypt(p_pin || '-ghd', gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
          '', '', '', '');
  INSERT INTO auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', p_email, 'email_verified', true),
          now(), now(), now());
END $$;

-- Aufruf aus der App (Einstellungen → Personen): nur die Chefin
CREATE OR REPLACE FUNCTION abw_login_setzen(p_person text, p_pin text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin darf Logins einrichten.'; END IF;
  SELECT name INTO v_name FROM abw_team WHERE id = p_person AND ausgeschieden_am IS NULL;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Person nicht gefunden.'; END IF;
  PERFORM abw__login_schreiben(abw__login_email(v_name), p_pin);
END $$;

REVOKE ALL ON FUNCTION abw__login_email(text), abw__login_schreiben(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION abw_login_setzen(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION abw_login_setzen(text, text) TO authenticated;

-- ── Einmalig: fehlende Konten nachziehen ───────────────────────
-- Legt für alle aktiven Personen, die in abw_team eine PIN haben, aber noch
-- kein Login-Konto, das Konto an (z. B. zuletzt angelegte Mitarbeiterinnen).
-- Bestehende Konten bleiben unverändert.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT t.name, t.pin::text AS pin FROM abw_team t
    WHERE t.ausgeschieden_am IS NULL
      AND t.pin::text ~ '^[0-9]{4}$'
      AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = abw__login_email(t.name))
  LOOP
    PERFORM abw__login_schreiben(abw__login_email(r.name), r.pin);
    RAISE NOTICE 'Login angelegt: %', r.name;
  END LOOP;
END $$;
