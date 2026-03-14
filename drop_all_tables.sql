-- Run this script in your Supabase SQL Editor to COMPLETELY WIPE your existing SpendX database tables.
-- This will delete ALL data in these tables and remove the tables themselves.
-- After running this, run `supabase_schema.sql` to recreate them perfectly.

DROP TABLE IF EXISTS public.emi_plans CASCADE;
DROP TABLE IF EXISTS public.credit_cards CASCADE;
DROP TABLE IF EXISTS public.lendings CASCADE;
DROP TABLE IF EXISTS public.fuel_logs CASCADE;
DROP TABLE IF EXISTS public.vehicles CASCADE;
DROP TABLE IF EXISTS public.recurring_templates CASCADE;
DROP TABLE IF EXISTS public.budgets CASCADE;
DROP TABLE IF EXISTS public.transactions CASCADE;
DROP TABLE IF EXISTS public.tags CASCADE;
DROP TABLE IF EXISTS public.categories CASCADE;
DROP TABLE IF EXISTS public.bank_accounts CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;

-- Optional: If you want to delete all users from auth as well to start 100% fresh, 
-- you can do that from the Authentication -> Users dashboard in Supabase manually.
