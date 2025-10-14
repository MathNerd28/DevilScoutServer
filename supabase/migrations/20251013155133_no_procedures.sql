drop procedure if exists "nexus"."merge_events"(IN events jsonb);

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
        t.data = d.event,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      THEN UPDATE SET
        t.delete_time = now();
  END;
$function$
;


drop procedure if exists "tba"."merge_districts"(IN year smallint, IN districts jsonb);

drop procedure if exists "tba"."merge_event_rankings"(IN event_key text, IN rankings jsonb);

drop procedure if exists "tba"."merge_event_teams"(IN event_key text, IN team_keys jsonb);

drop procedure if exists "tba"."merge_events"(IN year smallint, IN events jsonb);

drop procedure if exists "tba"."merge_matches"(IN event_key text, IN matches jsonb);

drop procedure if exists "tba"."merge_teams"(IN page smallint, IN teams jsonb);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.merge_districts(year smallint, districts jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION tba.merge_event_rankings(event_key text, rankings jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION tba.merge_event_teams(event_key text, team_keys jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements_text(team_keys) AS team_key
    )
    MERGE INTO tba.event_teams t
      USING data d ON
        t.event_key = event_key AND
        t.team_key = d.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key) VALUES
      (event_key, d.team_key)
    WHEN MATCHED
      THEN UPDATE SET
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key
      THEN UPDATE SET
        delete_time = now();
  END;
$function$
;

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
        t.data = d.event,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key LIKE (year::text || '%')
      THEN UPDATE SET
        t.delete_time = now();
  END;
$function$
;

CREATE OR REPLACE FUNCTION tba.merge_matches(event_key text, matches jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
        t.page = page,
        t.data = d.team,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.page = page
      THEN UPDATE SET
        t.delete_time = now();
  END;
$function$
;


