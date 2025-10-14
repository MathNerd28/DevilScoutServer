-- basic utilities for the rest of the security definitions

CREATE FUNCTION has_permission(p_type text) RETURNS boolean STRICT
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN EXISTS (
    SELECT 1 FROM permissions p
    WHERE
      p.user_id = (SELECT auth.uid()) AND
      p.type LIKE p_type
  );

CREATE FUNCTION get_team_num() RETURNS smallint
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN (
    SELECT team_num
      FROM team_users
      WHERE user_id = (SELECT auth.uid())
  );

CREATE FUNCTION is_user_on_same_team(id_user uuid) RETURNS boolean STRICT
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN (SELECT get_team_num()) = (
    SELECT team_num
      FROM team_users
      WHERE team_users.user_id = id_user
  );

-- Restrict everything by default
-- Only grant specific permissions

-- functions in public are meant to be executed by users
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public
  FROM public, anon;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA nexus
  FROM public, anon, authenticated;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA tba
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA nexus
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA tba
  FROM public, anon, authenticated;

DO $$
  DECLARE
    row RECORD;
  BEGIN
    FOR row IN (
      SELECT tablename
        FROM pg_tables AS t
        WHERE t.schemaname = 'public'
    )
    LOOP
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', row.tablename);
    END LOOP;
  END;
$$;

-- profiles -------------------------------
GRANT SELECT ON TABLE profiles TO authenticated;

CREATE POLICY "Anyone can SELECT themself or their team's members"
  ON profiles FOR SELECT TO authenticated
  USING (
    profiles.user_id = (SELECT auth.uid())
    OR
    is_user_on_same_team(profiles.user_id)
  );

CREATE POLICY "'team.%' can SELECT users requesting their team"
  ON profiles FOR SELECT TO authenticated
  USING (
    (SELECT has_permission('team.%'))
    AND
    profiles.user_id IN (
      SELECT user_id
        FROM team_requests
        WHERE team_num = (SELECT get_team_num())
    )
  );

GRANT ALL ON TABLE profiles TO supabase_auth_admin;

CREATE POLICY "Supabase Auth can read/write profiles"
ON profiles FOR ALL TO supabase_auth_admin
USING (true);

-- teams -------------------------------
GRANT SELECT, INSERT(number, name), UPDATE(name) ON TABLE teams TO authenticated;

CREATE POLICY "Anyone can SELECT any team"
  ON teams FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "Users not on a team can INSERT a new team"
  ON teams FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT get_team_num() IS NULL)
  );

CREATE POLICY "'team.admin' can UPDATE their team name"
  ON teams FOR UPDATE TO authenticated
  USING (
    (SELECT has_permission('team.admin'))
    AND
    number = (SELECT get_team_num())
  );

CREATE POLICY "'team.admin' can DELETE their team"
  ON teams FOR DELETE TO authenticated
  USING (
    (SELECT has_permission('team.admin'))
    AND
    number = (SELECT get_team_num())
  );

-- team_users --------------------------
GRANT SELECT, DELETE, INSERT (user_id, team_num) ON TABLE team_users TO authenticated;

CREATE POLICY "Team members can SELECT each other"
ON team_users FOR SELECT TO authenticated
USING (
  team_num = (SELECT get_team_num())
);

CREATE POLICY "Anyone can DELETE themself from their team"
ON team_users FOR DELETE TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.*' can DELETE users from their team"
ON team_users FOR DELETE TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

CREATE POLICY "'team.*' can INSERT users by request"
ON team_users FOR INSERT TO authenticated
WITH CHECK (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  (SELECT get_team_num()) = (
    SELECT team_requests.team_num
      FROM team_requests
      WHERE team_requests.user_id = team_users.user_id
  )
);

-- team_requests -----------------------
GRANT SELECT, DELETE, INSERT(team_num) ON TABLE team_requests TO authenticated;

CREATE POLICY "Anyone can SELECT, INSERT, or DELETE their request"
ON team_requests TO authenticated
USING (
  user_id = (SELECT auth.uid())
)
WITH CHECK(
  -- Not on a team already
  (SELECT get_team_num() IS NULL)
);

CREATE POLICY "'team.*' can SELECT requests"
ON team_requests FOR SELECT TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

CREATE POLICY "'team.*' can DELETE requests"
ON team_requests FOR DELETE TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

-- permission_types
GRANT SELECT ON TABLE permission_types TO authenticated;

CREATE POLICY "Anyone can SELECT permission types"
ON permission_types TO authenticated
USING (true);

-- permissions -------------------------
GRANT SELECT, DELETE, INSERT(user_id, type) ON TABLE permissions TO authenticated;

CREATE POLICY "Anyone can SELECT their own permissions"
ON permissions FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.*' can SELECT, INSERT, or DELETE permissions"
ON permissions TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

-- Allow anyone to select anything from frc_*
DO $$
DECLARE
  row RECORD;
BEGIN
  FOR row IN (
    SELECT tablename
    FROM pg_tables AS t
    WHERE t.schemaname = 'public'
    AND t.tablename LIKE 'frc_%'
  )
  LOOP
    EXECUTE format(
      '
      GRANT SELECT ON TABLE %1$I TO authenticated;

      CREATE POLICY "Anyone can SELECT anything"
        ON %1$I FOR SELECT TO authenticated
        USING (true);
      ',
      row.tablename
    );
  END LOOP;
END;
$$;

-- assigned_matches
GRANT SELECT, INSERT, DELETE ON TABLE assigned_matches TO authenticated;

CREATE POLICY "Users can SELECT their assigned matches"
ON assigned_matches FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.%' can SELECT, INSERT or DELETE assigned matches"
ON assigned_matches FOR ALL TO authenticated
USING (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
)
WITH CHECK (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
);

-- assigned_pits
GRANT SELECT, INSERT, DELETE ON TABLE assigned_pits TO authenticated;

CREATE POLICY "Users can SELECT their assigned pits"
ON assigned_pits FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.%' can SELECT, INSERT or DELETE assigned pits"
ON assigned_pits FOR ALL TO authenticated
USING (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
)
WITH CHECK (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
);

-- questions
GRANT SELECT ON TABLE questions TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions FOR SELECT TO authenticated
USING (true);

-- questions_integer
GRANT SELECT ON TABLE questions_integer TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_integer FOR SELECT TO authenticated
USING (true);

-- questions_options
GRANT SELECT ON TABLE questions_options TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_options FOR SELECT TO authenticated
USING (true);

-- questions_options_choices
GRANT SELECT ON TABLE questions_options_choices TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_options_choices FOR SELECT TO authenticated
USING (true);

-- submissions
GRANT SELECT, INSERT (category, event_key, match_key, season, scouted_team) ON TABLE submissions TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions FOR SELECT TO authenticated
USING (true);

CREATE POLICY "'scout.{category}' can INSERT {category} entries"
ON submissions FOR INSERT TO authenticated
WITH CHECK (
  has_permission(('scout.' || category))
);

-- submissions_data_integer
GRANT SELECT, INSERT ON TABLE submissions_data_integer TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions_data_integer FOR SELECT TO authenticated
USING (true);

CREATE POLICY "Anyone can INSERT data for their submission"
ON submissions_data_integer FOR INSERT TO authenticated
WITH CHECK (
  (
    SELECT
      (scouting_user = (SELECT auth.uid())) AND has_permission(('scout.' || category))
      FROM submissions
      WHERE submissions.id = submission_id
  )
);

-- submissions_data_options
GRANT SELECT, INSERT ON TABLE submissions_data_options TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions_data_options FOR SELECT TO authenticated
USING (true);

CREATE POLICY "Anyone can INSERT data for their submission"
ON submissions_data_options FOR INSERT TO authenticated
WITH CHECK (
  (
    SELECT
      (scouting_user = (SELECT auth.uid())) AND has_permission(('scout.' || category))
      FROM submissions
      WHERE submissions.id = submission_id
  )
);
