// SquadVault frontend configuration.
//
// Everything in this file is PUBLIC (it ships to every browser). That is fine for:
//   * the Supabase project URL
//   * the Supabase *publishable* key (sb_publishable_... or the legacy "anon" key)
// Row Level Security is what protects the data, not the secrecy of these values.
//
// NEVER put any of these here: service-role key, database password, IntaSend secret,
// webhook challenge. Those live only in Supabase Edge Function secrets (see README).
//
// To configure: paste your publishable key below (Supabase dashboard -> Project Settings -> API Keys).

export const config = Object.freeze({
  supabaseUrl: "https://mdvgvhnceouabyuhsbio.supabase.co",
  supabasePublishableKey: "sb_publishable_VlPybSF4CRsm1eaevFuxCg_jmvyNjr2", // public by design; RLS protects the data
  supabaseJsUrl: "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm",
  currency: "RWF",
  // Set true only after you deploy the IntaSend Edge Functions (README). Off = leader-managed MoMo number/code.
  onlinePayments: false,
  // Optional public contact shown in the Terms. Leave empty to hide it.
  contactEmail: "",
  limits: Object.freeze({
    minContribution: 100,
    maxContribution: 5_000_000,
    maxMoney: 1_000_000_000_000,
    receiptMaxBytes: 5 * 1024 * 1024,
    avatarMaxBytes: 1024 * 1024,
  }),
});

export function isConfigured() {
  return /^(sb_publishable_|eyJ)[\w.-]{10,}$/.test(config.supabasePublishableKey.trim());
}
