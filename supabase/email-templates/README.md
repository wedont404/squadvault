# Branded emails (so they stop looking like plain Supabase mail)

Supabase sends sign-up and password-reset emails itself, from its own address. Two changes make them yours.

## 1. Paste the templates (needed for the reset link to work from any browser)
Supabase dashboard -> **Authentication -> Email Templates**

| Template | Subject | Paste the body from |
|---|---|---|
| Confirm signup | Confirm your SquadVault account | `confirm-signup.html` |
| Reset password | Reset your SquadVault password | `reset-password.html` |
| Magic Link | Confirm your email on SquadVault | `magic-link.html` (sent when someone taps *Send confirmation email* to unlock chat and photos) |

Paste only the HTML (not the first comment) and Save. These links use `token_hash`, which SquadVault turns into a login
by itself, so they work even when the email is opened in a different browser or in a phone's mail app.
Without these templates the default links still work, but only in the same browser that asked for them.

Also check **Authentication -> URL Configuration**: **Site URL** and **Redirect URLs** must contain your site address
(e.g. `https://wedont404.github.io/squadvault/`).

## 2. Send from "SquadVault" instead of Supabase (custom SMTP)
Authentication -> **Emails -> SMTP Settings** -> turn on **Enable custom SMTP**.

Simplest option, using a Gmail account (about 500 emails a day):
1. On that Gmail account turn on 2-Step Verification, then create an **App password** (Google Account -> Security).
2. Fill in: Host `smtp.gmail.com`, Port `465`, Username = the Gmail address, Password = the 16-character app password.
3. Sender email = the same Gmail address, **Sender name = SquadVault**.

Emails then show "SquadVault" as the sender. For a fully professional sender (`no-reply@yourdomain`) use a domain you own with an
email service such as Resend or Brevo, then enter its SMTP details in the same place.

Supabase's built-in sender is limited to a few emails per hour, so custom SMTP also removes that limit.
