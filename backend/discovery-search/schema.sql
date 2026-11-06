-- Durable abuse limits for discovery-search. Apply only in the approved Mirsa-only project.
create table if not exists public.discovery_usage (
  bucket text not null,
  window_start timestamptz not null,
  n integer not null default 0,
  primary key (bucket, window_start)
);
alter table public.discovery_usage enable row level security;
revoke all on public.discovery_usage from public, anon, authenticated;

-- All-or-nothing: raises 'limit:<bucket>' (rolling back every counter) when any limit is hit.
create or replace function public.discovery_take(p_user uuid, p_ip text)
returns void language plpgsql security definer set search_path = public as $$
declare
  specs text[][] := array[
    ['user-hour:' || p_user::text, 'hour',  '20'],
    ['user-day:'  || p_user::text, 'day',   '60'],
    ['ip-hour:'   || p_ip,         'hour',  '60'],
    ['global-min',                 'minute','10'],
    ['global-day',                 'day',   '60'],
    ['global-month',               'month', '900']
  ];
  i int; ws timestamptz; cnt int;
begin
  for i in 1..array_length(specs,1) loop
    ws := date_trunc(specs[i][2], now());
    insert into discovery_usage(bucket, window_start, n) values (specs[i][1], ws, 1)
      on conflict (bucket, window_start) do update set n = discovery_usage.n + 1
      returning n into cnt;
    if cnt > specs[i][3]::int then
      raise exception 'limit:%', split_part(specs[i][1], ':', 1);
    end if;
  end loop;
  delete from discovery_usage where window_start < now() - interval '40 days' and random() < 0.01;
end $$;
revoke all on function public.discovery_take(uuid, text) from public, anon, authenticated;
grant execute on function public.discovery_take(uuid, text) to service_role;
