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
import { AREAS, SEVERITIES, STATUSES, TYPES } from "../src/lib/constants";

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
// A Notion column named "Status" is usually the dedicated Status property type
// (data at prop.status.name), not a Select. Fall back to select just in case.
function statusVal(prop: any): string | null {
  return prop?.status?.name ?? prop?.select?.name ?? null;
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

  // Track values that don't match our option lists so they can be reconciled.
  const offList: Record<string, Set<string>> = { status: new Set(), severity: new Set(), area: new Set(), type: new Set() };
  const note = (field: keyof typeof offList, value: string | null, allowed: readonly string[]) => {
    if (value && !allowed.includes(value)) offList[field].add(value);
    return value;
  };

  let imported = 0;
  for (const page of pages) {
    const p = page.properties;
    const nid = uniqueId(p["ID"]);
    const name = rich(p["Name"]) ?? "(untitled)";

    const data = {
      name,
      status: note("status", statusVal(p["Status"]), STATUSES) ?? "Backlog",
      severity: note("severity", select(p["Severity"]), SEVERITIES),
      area: note("area", select(p["Area"]), AREAS),
      type: note("type", select(p["Type"]), TYPES),
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

  // Surface any values that aren't in src/lib/constants.ts. They still import
  // and show on the board (in their own column / table), but won't have a
  // predefined color or appear in the dropdowns until you add them.
  for (const [field, set] of Object.entries(offList)) {
    if (set.size > 0) {
      console.warn(`⚠️  ${field}: values not in constants.ts → ${[...set].join(", ")}`);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
