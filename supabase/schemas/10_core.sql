-- User metadata
-- Synced with auth.users, but public-facing
CREATE TABLE profiles (
  user_id uuid PRIMARY KEY
    REFERENCES auth.users ON DELETE CASCADE,
  created_at timestamptz NOT NULL,
  name text NOT NULL
);

-- Team metadata, e.g. names
CREATE TABLE teams (
  created_at timestamptz NOT NULL
    DEFAULT now(),
  number smallint PRIMARY KEY,
  name text NOT NULL,

  -- fuzzy search by name/number
  search_term text NOT NULL
    GENERATED ALWAYS AS (number::text || name) STORED
);

CREATE INDEX ON teams USING GIN(search_term gin_trgm_ops);

-- User-team relationships
-- Each user may be on just a single team
-- Must explicitly set added_by to NULL to insert first member
-- Unique/FK order provides a useful second index instead of redundancy
CREATE TABLE team_users (
  user_id uuid PRIMARY KEY
    REFERENCES profiles ON DELETE CASCADE,
  added_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL
    REFERENCES teams ON DELETE CASCADE,
  added_by uuid
    DEFAULT auth.uid()
    REFERENCES profiles ON DELETE SET NULL,

  UNIQUE (team_num, user_id),
  FOREIGN KEY (team_num, added_by)
    REFERENCES team_users (team_num, user_id)
    ON DELETE SET NULL (added_by)
);

-- Requests by users to join teams
-- Users may have at most one request open
-- Requests require that the user is not on a team
CREATE TABLE team_requests (
  user_id uuid PRIMARY KEY
    REFERENCES profiles ON DELETE CASCADE,
  requested_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL
    REFERENCES teams ON DELETE CASCADE
);

CREATE INDEX ON team_requests (team_num, requested_at);

CREATE FUNCTION validate_team_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.team_users
    WHERE user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Team member % cannot request to join a team', NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate
  BEFORE INSERT ON public.team_requests
  FOR EACH ROW EXECUTE FUNCTION validate_team_request();

CREATE FUNCTION delete_team_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM public.team_requests request
    WHERE request.user_id = NEW.user_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER delete_request
  AFTER INSERT ON public.team_users
  FOR EACH ROW EXECUTE FUNCTION delete_team_request();

-- Types of permissions
-- Not writable except manually by service_role
-- See seed for types
CREATE TABLE permission_types (
  id text PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL
    DEFAULT ''
);

-- User permissions
CREATE TABLE permissions (
  user_id uuid NOT NULL,
  granted_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL,
  type text NOT NULL
    REFERENCES permission_types,
  granted_by uuid
    DEFAULT auth.uid(),

  PRIMARY KEY (user_id, type),
  FOREIGN KEY (team_num, user_id)
    REFERENCES team_users (team_num, user_id)
    ON DELETE CASCADE,
  FOREIGN KEY (team_num, granted_by)
    REFERENCES team_users (team_num, user_id)
    ON DELETE SET NULL (granted_by)
);

CREATE FUNCTION require_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF (
    OLD.type = 'team.admin'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.permissions
    WHERE
      team_num = OLD.team_num AND
      type = 'team.admin'
  ) AND EXISTS (
    SELECT 1 FROM public.teams
    WHERE number = OLD.team_num
  ) THEN
    RAISE EXCEPTION 'Team % must have at least one member with team.admin permission', OLD.team_num;
  END IF;

  RETURN NEW;
END;
$$;

GRANT SELECT ON TABLE teams TO supabase_auth_admin;

-- deferrable for deleting a team
CREATE CONSTRAINT TRIGGER on_delete
  AFTER DELETE ON permissions DEFERRABLE
  FOR EACH ROW EXECUTE FUNCTION require_admin();

-- Users automatically gain privileges when creating a team
CREATE FUNCTION teams_register()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
  THEN
    -- Make the user a member
    INSERT INTO team_users
      (user_id, team_num) VALUES
      (auth.uid(), NEW.number);

    -- Grant them all permissions
    INSERT INTO permissions
      (user_id, team_num, type)
      (
        SELECT
          (SELECT auth.uid()),
          NEW.number,
          id
        FROM permission_types
      );
  END IF;

  IF NOT NEW.verified
  THEN
    -- Notify developers of new unverified team via email
    PERFORM net.http_post(
      url := 'https://api.resend.com/emails',
      body := jsonb_build_object(
        'from', 'Devil Scout Notifier <notify@devilscout.org>',
        'to', 'devilscoutfrc@gmail.com',
        'subject', 'Unverified Team Created',
        'html', format(
          '<p>Dear Developer,</p>'
          '<p>A user just registered team %s, which is marked as unverified in the database. Please review the team''s owner and mark the team as verified.</p>'
          '<p>Best, Devil Scout''s Database</p>', NEW.number
        )
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'resend_api_key'
        )
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION teams_register FROM public, anon;

CREATE TRIGGER teams_register
  AFTER INSERT ON teams
  FOR EACH ROW EXECUTE FUNCTION teams_register();
