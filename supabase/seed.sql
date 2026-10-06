-- Seed local (supabase db reset). Sin datos sensibles.
-- DQR-T013: no se siembran usuarios ni organizaciones; los tests SQL
-- (supabase/tests) crean sus propios datos dentro de BEGIN … ROLLBACK.
select 1;
