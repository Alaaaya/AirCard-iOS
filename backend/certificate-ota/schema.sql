create table if not exists public.mirsa_ota_jobs (
 token text primary key check (length(token)=64),
 owner uuid not null references auth.users(id) on delete cascade,
 bytes bigint not null check (bytes between 4 and 31457280),
 metadata jsonb not null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '15 minutes',
 ready boolean not null default false,
 downloads integer not null default 0
);
alter table public.mirsa_ota_jobs enable row level security;
revoke all on public.mirsa_ota_jobs from anon,authenticated;
create or replace function public.mirsa_ota_reserve(p_owner uuid,p_token text,p_bytes bigint,p_metadata jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
 perform pg_advisory_xact_lock(773201866);
 -- Hard global caps limit storage and egress independently of sign-up abuse.
 if (select count(*) from mirsa_ota_jobs where created_at>now()-interval '1 day')>=20
 or (select coalesce(sum(bytes),0) from mirsa_ota_jobs where created_at>now()-interval '1 day')+p_bytes>209715200
 or (select count(*) from mirsa_ota_jobs where owner=p_owner and created_at>now()-interval '1 hour')>=3
 or (select count(*) from mirsa_ota_jobs where expires_at>now())>=5 then
 raise exception 'quota'; end if;
 insert into mirsa_ota_jobs(token,owner,bytes,metadata) values(p_token,p_owner,p_bytes,p_metadata);
end $$;
revoke all on function public.mirsa_ota_reserve(uuid,text,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.mirsa_ota_reserve(uuid,text,bigint,jsonb) to service_role;
create or replace function public.mirsa_ota_download(p_token text)
returns setof public.mirsa_ota_jobs language sql security definer set search_path=public as $$
 update mirsa_ota_jobs set downloads=downloads+1
 where token=p_token and ready and expires_at>now() and downloads<8
 returning *;
$$;
revoke all on function public.mirsa_ota_download(text) from public,anon,authenticated;
grant execute on function public.mirsa_ota_download(text) to service_role;
-- Durable monthly budget is separate from short-lived download jobs.
create table if not exists public.mirsa_ota_usage (
 token text primary key, owner uuid not null, bytes bigint not null, created_at timestamptz not null default now()
);
alter table public.mirsa_ota_usage enable row level security;
revoke all on public.mirsa_ota_usage from anon,authenticated;
create or replace function public.mirsa_ota_reserve(p_owner uuid,p_token text,p_bytes bigint,p_metadata jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
 perform pg_advisory_xact_lock(773201866);
 if p_bytes<4 or p_bytes>31457280 then raise exception 'size'; end if;
 if (select count(*) from mirsa_ota_usage where created_at>now()-interval '1 day')>=20
 or (select coalesce(sum(bytes),0) from mirsa_ota_usage where created_at>now()-interval '31 days')+p_bytes>419430400
 or (select coalesce(sum(bytes),0) from mirsa_ota_usage where created_at>now()-interval '1 day')+p_bytes>209715200
 or (select count(*) from mirsa_ota_usage where owner=p_owner and created_at>now()-interval '1 hour')>=3
 or (select count(*) from mirsa_ota_jobs where expires_at>now())>=5 then
 raise exception 'quota'; end if;
 insert into mirsa_ota_usage(token,owner,bytes) values(p_token,p_owner,p_bytes);
 insert into mirsa_ota_jobs(token,owner,bytes,metadata) values(p_token,p_owner,p_bytes,p_metadata);
 delete from mirsa_ota_usage where created_at<now()-interval '32 days';
end $$;
