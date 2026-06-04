/**
 * One-time migration: pull every page from the Notion "Scopas Bug Board"
 * database and load it into this app's Postgres DB, preserving the original
 * SCOPAS-### IDs.
 *
 * Setup:
 *   1. Create an internal integration: https://www.notion.so/my-integrations
 *   2. Open the Scopas Bug Board in Notion → ••• → Connections → add it.
 *   3. Put NOTION_TOKEN and NOTION_DATABASE_ID in .env
 *   4. npm run db:migrate-notion
 */
import { prisma } from "../src/lib/db";

const TOKEN = process.env.NOTION_TOKEN;
const DB_ID = process.env.NOTION_DATABASE_ID;
const NOTION_VERSION = "2022-06-28";

function rich(prop: any): string | null {
  const arr = prop?.rich_text ?? prop?.title;
  if (!Array.isArray(arr) || arr.length === 0) return null;
  return arr.map((t: any) => t.plain_text).join("") || null;
}
function select(prop: any): string | null {
  return prop?.select?.name ?? null;
}
function checkbox(prop: any): boolean {
  return Boolean(prop?.checkbox);
}
function uniqueId(prop: any): number | null {
  return typeof prop?.unique_id?.number === "number" ? prop.unique_id.number : null;
}

async function queryAll() {
  const pages: any[] = [];
  let cursor: string | undefined = undefined;
  do {
    const res = await fetch(`https://api.notion.com/v1/databases/${DB_ID}/query`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ page_size: 100, start_cursor: cursor }),
    });
    if (!res.ok) {
      throw new Error(`Notion query failed (${res.status}): ${await res.text()}`);
    }
    const data: any = await res.json();
    pages.push(...data.results);
    cursor = data.has_more ? data.next_cursor : undefined;
  } while (cursor);
  return pages;
}

async function main() {
  if (!TOKEN || !DB_ID) {
    throw new Error("Set NOTION_TOKEN and NOTION_DATABASE_ID in .env first.");
  }
  console.log("Fetching pages from Notion…");
  const pages = await queryAll();
  console.log(`Got ${pages.length} pages. Importing…`);

  let imported = 0;
  for (const page of pages) {
    const p = page.properties;
    const nid = uniqueId(p["ID"]);
    const name = rich(p["Name"]) ?? "(untitled)";

    const data = {
      name,
      status: select(p["Status"]) ?? "Backlog",
      severity: select(p["Severity"]),
      area: select(p["Area"]),
      type: select(p["Type"]),
      details: rich(p["Details"]),
      summary: rich(p["Summary"]),
      file: rich(p["File"]),
      suggestedFix: rich(p["Suggested Fix"]),
      isolatedFix: checkbox(p["Isolated Fix"]),
      isolationNotes: rich(p["Isolation Notes"]),
    };

    if (nid != null) {
      await prisma.issue.upsert({
        where: { id: nid },
        create: { id: nid, ...data },
        update: data,
      });
    } else {
      await prisma.issue.create({ data });
    }
    imported++;
  }

  // Make Postgres autoincrement continue past the largest imported id.
  const max = await prisma.issue.aggregate({ _max: { id: true } });
  if (max._max.id) {
    await prisma.$executeRawUnsafe(
      `SELECT setval(pg_get_serial_sequence('"Issue"', 'id'), ${max._max.id}, true)`,
    );
  }

  console.log(`✅ Imported ${imported} issues. Sequence reset to ${max._max.id ?? 0}.`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
