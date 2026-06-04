# Scopa Board

An in-house bug & issue tracker — a self-hosted, Jira/Notion-style board that
mirrors the **Scopas Bug Board** schema. Built with Next.js + Prisma + Postgres.
You own the code; host it anywhere for $0.

## Features

- **Board (Kanban) views** grouped by Status, Severity, or Area — drag cards
  between columns to update them.
- **Table views** with the same data.
- **8 saved views** recreating the Notion ones: Board by Status / Severity /
  Area, All issues, 🔥 P0 + P1, 🚨 P0s by Area, 💰 Money loss, 🟢 Ship Now — Isolated.
- **Full issue schema**: Name, ID (`SCOPAS-###`), Status, Severity (P0–P3),
  Area, Type, Summary, Details, File, Suggested Fix, Isolated Fix + notes — plus
  a new **Assignee** field the Notion board lacked.
- **Comments** per issue.
- **Search** across name / summary / file / area / type / ID.
- **Shared-password login** (one team password).

## Tech

Next.js 14 (App Router) · React · Tailwind · Prisma · PostgreSQL.

---

## Quick start (local dev)

```bash
npm install
cp .env.example .env          # set APP_PASSWORD, SESSION_SECRET, DATABASE_URL
npx prisma db push            # create tables
npm run db:seed               # optional: a few sample issues
npm run dev                   # http://localhost:3000
```

`SESSION_SECRET`: generate with `openssl rand -hex 32`.

## Import your real data from Notion

1. Create an internal integration at <https://www.notion.so/my-integrations>.
2. In Notion, open **Scopas Bug Board → ••• → Connections** and add the integration.
3. Put `NOTION_TOKEN` (the integration secret) and `NOTION_DATABASE_ID` in `.env`
   (the database id is pre-filled in `.env.example`).
4. Run:
   ```bash
   npm run db:migrate-notion
   ```
   This preserves the original `SCOPAS-###` IDs and resets the autoincrement
   sequence so new issues continue from the right number.

---

## Deploy for free

### Option A — Vercel + Neon/Supabase (recommended, $0)

1. Create a free Postgres at [Neon](https://neon.tech) or
   [Supabase](https://supabase.com); copy its connection string.
2. Push this repo to GitHub, import it in [Vercel](https://vercel.com).
3. In Vercel → Project → Settings → Environment Variables, set:
   `DATABASE_URL`, `APP_PASSWORD`, `SESSION_SECRET`, `ISSUE_PREFIX`.
4. Deploy. After the first deploy, run `npx prisma db push` against the prod
   DB once (locally with prod `DATABASE_URL`, or via a one-off job), then run
   the Notion migration the same way.

The `build` script runs `prisma generate` automatically.

### Option B — Docker, anywhere (AWS / GCP / a VM)

```bash
cp .env.example .env          # set APP_PASSWORD + SESSION_SECRET
docker compose up --build     # app on :3000, Postgres alongside
```

This brings up the app **and** a Postgres container, applies the schema on
boot, and is cloud-agnostic — deploy the same image to AWS App Runner / ECS,
Google Cloud Run, Fly.io, or a bare VM (point `DATABASE_URL` at a managed DB
in production instead of the bundled container).

---

## Project layout

```
prisma/schema.prisma          data model (Issue, Comment)
prisma/seed.ts                sample data
scripts/migrate-from-notion.ts  one-time Notion → Postgres import
src/lib/constants.ts          field options, colors, saved-view presets
src/lib/auth.ts               shared-password session cookie
src/middleware.ts             route protection
src/app/api/...               REST endpoints (issues, comments, auth)
src/components/...             BoardApp, BoardView, TableView, IssueModal
```

## Customizing

- **Add/rename fields or options:** edit `src/lib/constants.ts` (and
  `prisma/schema.prisma` for new columns, then `npx prisma db push`).
- **Change the ID prefix:** set `ISSUE_PREFIX` (default `SCOPAS`).
- **Add real per-user accounts later:** swap the shared-password check in
  `src/lib/auth.ts` for NextAuth; the `assignee` field is already in place.
