-- Run this script in your Supabase SQL Editor if you get a "foreign key constraint" error
-- regarding "budgets_category_id_fkey" and incompatible types (text and uuid).

-- This happens because you likely created the `categories` table manually before, 
-- and set the `id` column to type `uuid` instead of `text`.

-- 1. First, we need to drop any existing foreign key constraints that depend on the UUID categories ID
ALTER TABLE IF EXISTS public.budgets DROP CONSTRAINT IF EXISTS budgets_category_id_fkey;
ALTER TABLE IF EXISTS public.transactions DROP CONSTRAINT IF EXISTS transactions_category_id_fkey;
ALTER TABLE IF EXISTS public.recurring_templates DROP CONSTRAINT IF EXISTS recurring_templates_category_id_fkey;

-- 2. Now we can safely alter the `id` column in `categories` to be standard TEXT
ALTER TABLE public.categories ALTER COLUMN id TYPE TEXT USING id::TEXT;

-- 3. Now re-add the Foreign Key constraints properly as TEXT references
ALTER TABLE public.budgets ADD CONSTRAINT budgets_category_id_fkey 
    FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE CASCADE;

ALTER TABLE public.transactions ADD CONSTRAINT transactions_category_id_fkey 
    FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL;

ALTER TABLE public.recurring_templates ADD CONSTRAINT recurring_templates_category_id_fkey 
    FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL;
