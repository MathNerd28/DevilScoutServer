alter table "nexus"."event_data" add column "delete_time" timestamp with time zone;

alter table "nexus"."pit_addresses" add column "delete_time" timestamp with time zone;

alter table "nexus"."pit_maps" add column "delete_time" timestamp with time zone;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION nexus.update_time()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    BEGIN
      IF NEW.delete_time IS NULL THEN
        NEW.update_time := now();
      END IF;

      RETURN NEW;
    END;
  $function$
;

CREATE TRIGGER event_data_update_time BEFORE UPDATE ON nexus.event_data FOR EACH ROW EXECUTE FUNCTION nexus.update_time();

CREATE TRIGGER events_update_time BEFORE UPDATE ON nexus.events FOR EACH ROW EXECUTE FUNCTION nexus.update_time();

CREATE TRIGGER pit_addresses_update_time BEFORE UPDATE ON nexus.pit_addresses FOR EACH ROW EXECUTE FUNCTION nexus.update_time();

CREATE TRIGGER pit_maps_update_time BEFORE UPDATE ON nexus.pit_maps FOR EACH ROW EXECUTE FUNCTION nexus.update_time();


