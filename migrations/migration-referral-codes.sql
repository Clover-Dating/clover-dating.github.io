-- Migration: Add referral system to email_signups
-- Run this in the Supabase SQL Editor

-- 1. Function to generate random 8-char alphanumeric codes
CREATE OR REPLACE FUNCTION generate_referral_code() RETURNS TEXT AS $$
DECLARE
  chars TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  code TEXT := '';
  i INT;
BEGIN
  FOR i IN 1..8 LOOP
    code := code || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  END LOOP;
  RETURN code;
END;
$$ LANGUAGE plpgsql;

-- 2. Add new columns
ALTER TABLE email_signups ADD COLUMN referral_code TEXT UNIQUE;
ALTER TABLE email_signups ADD COLUMN referred_by TEXT;

-- 3. Backfill existing rows
UPDATE email_signups SET referral_code = generate_referral_code() WHERE referral_code IS NULL;

-- 4. Make referral_code NOT NULL with auto-generation default
ALTER TABLE email_signups ALTER COLUMN referral_code SET NOT NULL;
ALTER TABLE email_signups ALTER COLUMN referral_code SET DEFAULT generate_referral_code();
