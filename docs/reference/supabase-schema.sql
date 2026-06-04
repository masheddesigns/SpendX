-- SpendX Supabase Schema Definition
-- Run this in your Supabase SQL Editor to ensure your cloud database perfectly matches the local SQLite schema.

-- 1. Profiles (Automatically linked to Auth Users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID REFERENCES auth.users(id) PRIMARY KEY,
  email TEXT NOT NULL,
  name TEXT,
  currency TEXT DEFAULT 'USD',
  timezone TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Note: Enable row level security (RLS) on all tables for production.
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can only see and modify their own profile" ON public.profiles FOR ALL USING (auth.uid() = id);

-- Note: If you previously created categories with `id UUID`, please run:
-- ALTER TABLE public.categories ALTER COLUMN id TYPE TEXT USING id::TEXT;
-- 2. Categories
CREATE TABLE IF NOT EXISTS public.categories (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  name TEXT NOT NULL,
  icon TEXT NOT NULL,
  color TEXT NOT NULL,
  type TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 3. Tags
CREATE TABLE IF NOT EXISTS public.tags (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 4. Transactions
CREATE TABLE IF NOT EXISTS public.transactions (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  type TEXT NOT NULL,
  category_id TEXT REFERENCES public.categories(id) ON DELETE SET NULL,
  amount REAL NOT NULL,
  date TIMESTAMP WITH TIME ZONE NOT NULL,
  notes TEXT,
  tags TEXT, -- Stored as comma-separated string locally, keeping same for easy sync
  source TEXT NOT NULL, -- manual, vehicle, recurring, etc.
  related_entity_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 5. Budgets
CREATE TABLE IF NOT EXISTS public.budgets (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  category_id TEXT REFERENCES public.categories(id) ON DELETE CASCADE,
  limit_amount REAL NOT NULL,
  period TEXT NOT NULL DEFAULT 'monthly',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 6. Recurring Templates
CREATE TABLE IF NOT EXISTS public.recurring_templates (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  title TEXT NOT NULL,
  amount REAL NOT NULL,
  type TEXT NOT NULL,
  category_id TEXT REFERENCES public.categories(id) ON DELETE SET NULL,
  frequency TEXT NOT NULL,
  start_date TIMESTAMP WITH TIME ZONE NOT NULL,
  next_date TIMESTAMP WITH TIME ZONE,
  end_date TIMESTAMP WITH TIME ZONE,
  last_processed_date TIMESTAMP WITH TIME ZONE,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 7. Vehicles
CREATE TABLE IF NOT EXISTS public.vehicles (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  license_plate TEXT,
  initial_odometer REAL NOT NULL,
  tank_capacity REAL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 8. Fuel Logs
CREATE TABLE IF NOT EXISTS public.fuel_logs (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  vehicle_id TEXT REFERENCES public.vehicles(id) ON DELETE CASCADE,
  date TIMESTAMP WITH TIME ZONE NOT NULL,
  odometer REAL NOT NULL,
  fuel_amount REAL NOT NULL,
  total_cost REAL NOT NULL,
  location TEXT,
  is_full_tank INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 9. Lendings
CREATE TABLE IF NOT EXISTS public.lendings (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  person_name TEXT NOT NULL,
  type TEXT NOT NULL,
  original_amount REAL NOT NULL,
  paid_amount REAL NOT NULL DEFAULT 0,
  date TIMESTAMP WITH TIME ZONE NOT NULL,
  due_date TIMESTAMP WITH TIME ZONE,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 10. Credit Cards
CREATE TABLE IF NOT EXISTS public.credit_cards (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  name TEXT NOT NULL,
  card_network TEXT NOT NULL,
  last_four_digits TEXT,
  credit_limit REAL NOT NULL,
  billing_day INTEGER NOT NULL,
  due_day INTEGER NOT NULL,
  outstanding_balance REAL NOT NULL DEFAULT 0,
  color TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 11. EMI Plans
CREATE TABLE IF NOT EXISTS public.emi_plans (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  credit_card_id TEXT REFERENCES public.credit_cards(id) ON DELETE CASCADE,
  item_name TEXT NOT NULL,
  principal_amount REAL NOT NULL,
  interest_rate REAL NOT NULL,
  tenure_months INTEGER NOT NULL,
  emi_amount REAL NOT NULL,
  start_date TIMESTAMP WITH TIME ZONE NOT NULL,
  paid_instalments INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 12. Bank Accounts
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  name TEXT NOT NULL,
  bank TEXT NOT NULL,
  account_type TEXT NOT NULL DEFAULT 'savings',
  balance REAL NOT NULL DEFAULT 0,
  color TEXT NOT NULL DEFAULT '#10B981',
  icon TEXT NOT NULL DEFAULT 'account_balance',
  is_asset INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- RLS Configuration for all subsequent tables
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recurring_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lendings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emi_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can only manage their own categories" ON public.categories FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own tags" ON public.tags FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own transactions" ON public.transactions FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own budgets" ON public.budgets FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own recurring_templates" ON public.recurring_templates FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own vehicles" ON public.vehicles FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own fuel_logs" ON public.fuel_logs FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own lendings" ON public.lendings FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own credit_cards" ON public.credit_cards FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own emi_plans" ON public.emi_plans FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "Users can only manage their own bank_accounts" ON public.bank_accounts FOR ALL USING (auth.uid() = user_id);
