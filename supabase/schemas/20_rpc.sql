CREATE FUNCTION auth_delete_user()
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM auth.users
    WHERE id = (SELECT auth.uid());
END;
$$;

CREATE FUNCTION frc_teams_search(query text)
RETURNS SETOF smallint
LANGUAGE sql
STABLE
AS $$
  SELECT frc_teams.number
    FROM frc_teams
      LEFT JOIN teams ON frc_teams.number = teams.number
    ORDER BY greatest(
      similarity(frc_teams.number::text, query),
      similarity(frc_teams.name, query),
      similarity(teams.name, query)
    ) DESC, frc_teams.number ASC;
$$;

CREATE FUNCTION frc_events_search(year smallint, query text)
RETURNS SETOF citext
LANGUAGE sql
STABLE
AS $$
  SELECT e.key
    FROM frc_events e
    WHERE e.season = year
    ORDER BY greatest(
      similarity(e.key::text, query),
      similarity(e.name::text, query)
    ) DESC, e.key ASC;
$$;

-- sync all current events
CREATE FUNCTION nexus.merge_events(events jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT tmp.key AS event_key, tmp.value AS event
      FROM jsonb_each(events) AS tmp (key, value)
    )
    MERGE INTO nexus.events n
      USING data d ON
        d.event_key = n.event_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, data) VALUES
      (d.event_key, d.event)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.event,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the events in a given year
CREATE FUNCTION tba.merge_events(year smallint, events jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(events) AS event
    )
    MERGE INTO tba.events t
      USING data d ON
        d.event->>'key' = t.event_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, data) VALUES
      (d.event->>'key', d.event)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.event,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key LIKE (year::text || '%')
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the teams on a given page
CREATE FUNCTION tba.merge_teams(page smallint, teams jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  DECLARE
    page_param ALIAS FOR page;
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(teams) AS team
    )
    MERGE INTO tba.teams t
      USING data d ON
        d.team->>'key' = t.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (team_key, page, data) VALUES
      (d.team->>'key', page_param, d.team)
    WHEN MATCHED
      THEN UPDATE SET
        page = page_param,
        data = d.team,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.page = page_param
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the teams in a given event
CREATE FUNCTION tba.merge_event_teams(event_key text, team_keys jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  DECLARE
    event_key_param ALIAS FOR event_key;
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements_text(team_keys) AS team_key
    )
    MERGE INTO tba.event_teams t
      USING data d ON
        t.event_key = event_key_param AND
        t.team_key = d.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key) VALUES
      (event_key_param, d.team_key)
    WHEN MATCHED
      THEN UPDATE SET
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key_param
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the matches in a given event
CREATE FUNCTION tba.merge_matches(event_key text, matches jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(matches) AS match
    )
    MERGE INTO tba.matches t
      USING data d ON
        t.match_key = d.match->>'key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (match_key, data) VALUES
      (d.match->>'key', d.match)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.match,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.match_key LIKE (event_key || '_%')
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the districts in a given year
CREATE FUNCTION tba.merge_districts(year smallint, districts jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(districts) AS district
    )
    MERGE INTO tba.districts t
      USING data d ON
        t.district_key = d.district->>'key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (district_key, data) VALUES
      (d.district->>'key', d.district)
    WHEN MATCHED
    THEN UPDATE SET
        data = d.district,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.district_key LIKE (year::text || '%')
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all rankings for a given event
CREATE FUNCTION tba.merge_event_rankings(event_key text, rankings jsonb) RETURNS VOID
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(rankings) AS rank
    )
    MERGE INTO tba.event_rankings t
      USING data d ON
        t.event_key = event_key AND
        t.team_key = d.rank->>'team_key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key, data) VALUES
      (event_key, d.rank->>'team_key', d.rank)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.rank,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key
      THEN UPDATE SET
        delete_time = now();
  END;
$$;
