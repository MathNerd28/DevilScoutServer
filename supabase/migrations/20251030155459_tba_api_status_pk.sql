alter table "tba"."api_status" add column "id" smallint not null default 1;

CREATE UNIQUE INDEX api_status_pkey ON tba.api_status USING btree (id);

alter table "tba"."api_status" add constraint "api_status_pkey" PRIMARY KEY using index "api_status_pkey";
