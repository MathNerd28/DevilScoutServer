drop trigger if exists "event_teams_insert" on "public"."frc_event_teams";


CREATE TRIGGER event_teams_insert AFTER INSERT ON tba.event_teams FOR EACH ROW EXECUTE FUNCTION tba.event_teams_trigger();


