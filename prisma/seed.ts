/**
 * Seed a few sample issues so the board isn't empty on first run.
 * For real data, use `npm run db:migrate-notion` instead.
 */
import { prisma } from "../src/lib/db";

const samples = [
  {
    name: "[Extension] Chrome extension frozen — click-through feature unresponsive",
    status: "Backlog",
    severity: "P1",
    area: "Extension",
    type: "Bug / UX",
    summary: "Popup overlay stops responding to clicks after a comparison is triggered.",
    file: "extension/src/content/overlay.ts",
    isolatedFix: false,
  },
  {
    name: "[Backend] Bump spin-wheel jackpot 500 → 1000 coins",
    status: "In Progress",
    severity: "P2",
    area: "Backend / Gamification",
    type: "Config",
    summary: "Increase jackpot payout per product spec.",
    isolatedFix: true,
    isolationNotes: "Single config constant; no schema change.",
  },
  {
    name: "[iOS] Auth tokens stored in UserDefaults instead of Keychain",
    status: "Backlog",
    severity: "P0",
    area: "iOS",
    type: "Security / Privacy",
    summary: "Sensitive tokens persisted unencrypted.",
    file: "extension/safari-app/SCOPA/SCOPA/iOS/TokenStore.swift",
    isolatedFix: true,
    isolationNotes: "Swap storage layer behind existing TokenStore interface.",
  },
];

async function main() {
  const count = await prisma.issue.count();
  if (count > 0) {
    console.log(`DB already has ${count} issues; skipping seed.`);
    return;
  }
  for (const s of samples) await prisma.issue.create({ data: s });
  console.log(`Seeded ${samples.length} sample issues.`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
