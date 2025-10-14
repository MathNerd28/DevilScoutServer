set check_function_bodies = off;

CREATE OR REPLACE FUNCTION nexus.merge_events(events jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;


set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.merge_events(year smallint, events jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION tba.merge_teams(page smallint, teams jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
      (d.team->>'key', page, d.team)
    WHEN MATCHED
      THEN UPDATE SET
        page = page,
        data = d.team,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.page = page
      THEN UPDATE SET
        delete_time = now();
  END;
$function$
;


