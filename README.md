# Viral Fleek POS

Point of sale, bookings, lay-by, stock, cash-up and bookkeeping for Viral Fleek. Built and supported by Lutho Lwame (Pty) Ltd.

- App: static site (`index.html`, `sw.js`, `manifest.json`), hosted on GitHub Pages.
- Data: Supabase (Postgres) with row-level security per shop. Schema in `sql/`.
- `config.js` holds the Supabase URL and publishable key only. No secrets live in this repository.
