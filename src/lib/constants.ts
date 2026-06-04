// Field options mirrored 1:1 from the Notion "Scopas Bug Board" schema.
// Order matters: it defines column/group order in the UI.

export const STATUSES = [
  "Backlog",
  "In Progress",
  "Open PR",
  "PR Review",
  "QA Testing",
  "Done",
] as const;

export const SEVERITIES = ["P0", "P1", "P2", "P3"] as const;

export const AREAS = [
  "Backend / Security",
  "Backend / Payments",
  "Backend / Auth",
  "Backend / Wallet",
  "Backend / Ops",
  "Backend / Logging",
  "Backend / Coupons",
  "Backend / Events",
  "Backend / Cron",
  "Backend / Gamification",
  "Backend / Tracking",
  "Backend / Tech debt",
  "Extension",
  "Extension / Security",
  "Extension / Features",
  "Repo / QA",
  "iOS",
  "Web",
] as const;

export const TYPES = [
  "Security",
  "Security / Secret leak",
  "Security / Compliance",
  "Security / Config",
  "Security / Privacy",
  "Bug",
  "Bug / Money loss",
  "Bug / Anti-exploit",
  "Bug / Data integrity",
  "Bug / UX",
  "Possible bug",
  "Config",
  "Missing feature",
  "Tech debt",
  "Inconsistency",
] as const;

export type Status = (typeof STATUSES)[number];
export type Severity = (typeof SEVERITIES)[number];

// Tailwind-friendly color classes (text + subtle bg) for each option group.
type Swatch = { dot: string; chip: string };

const SW = (dot: string, chip: string): Swatch => ({ dot, chip });

export const STATUS_COLORS: Record<string, Swatch> = {
  Backlog: SW("bg-zinc-500", "bg-zinc-500/15 text-zinc-300"),
  "In Progress": SW("bg-blue-500", "bg-blue-500/15 text-blue-300"),
  "Open PR": SW("bg-purple-500", "bg-purple-500/15 text-purple-300"),
  "PR Review": SW("bg-yellow-500", "bg-yellow-500/15 text-yellow-300"),
  "QA Testing": SW("bg-pink-500", "bg-pink-500/15 text-pink-300"),
  Done: SW("bg-green-500", "bg-green-500/15 text-green-300"),
};

export const SEVERITY_COLORS: Record<string, Swatch> = {
  P0: SW("bg-red-500", "bg-red-500/15 text-red-300"),
  P1: SW("bg-orange-500", "bg-orange-500/15 text-orange-300"),
  P2: SW("bg-yellow-500", "bg-yellow-500/15 text-yellow-300"),
  P3: SW("bg-zinc-500", "bg-zinc-500/15 text-zinc-300"),
};

// Area/Type are colored by their family prefix.
function familyColor(value: string): Swatch {
  if (value.startsWith("Security") || value.startsWith("Bug / Money") || value.startsWith("Bug / Anti"))
    return SW("bg-red-500", "bg-red-500/15 text-red-300");
  if (value.startsWith("Backend / Payments") || value.startsWith("Backend / Wallet"))
    return SW("bg-orange-500", "bg-orange-500/15 text-orange-300");
  if (value.startsWith("Bug")) return SW("bg-orange-500", "bg-orange-500/15 text-orange-300");
  if (value.startsWith("Extension")) return SW("bg-purple-500", "bg-purple-500/15 text-purple-300");
  if (value === "iOS") return SW("bg-pink-500", "bg-pink-500/15 text-pink-300");
  if (value === "Web") return SW("bg-amber-700", "bg-amber-700/20 text-amber-300");
  if (value.startsWith("Missing")) return SW("bg-purple-500", "bg-purple-500/15 text-purple-300");
  if (value.startsWith("Config")) return SW("bg-blue-500", "bg-blue-500/15 text-blue-300");
  if (value.startsWith("Possible")) return SW("bg-yellow-500", "bg-yellow-500/15 text-yellow-300");
  return SW("bg-zinc-500", "bg-zinc-500/15 text-zinc-300");
}

export function swatchFor(field: string, value: string | null | undefined): Swatch {
  if (!value) return SW("bg-zinc-700", "bg-zinc-700/30 text-zinc-400");
  if (field === "status") return STATUS_COLORS[value] ?? familyColor(value);
  if (field === "severity") return SEVERITY_COLORS[value] ?? familyColor(value);
  return familyColor(value);
}

export const ISSUE_PREFIX = process.env.ISSUE_PREFIX || process.env.NEXT_PUBLIC_ISSUE_PREFIX || "SCOPAS";
export function issueKey(id: number): string {
  return `${ISSUE_PREFIX}-${id}`;
}

// Saved view presets recreating the Notion views.
export type ViewPreset = {
  id: string;
  name: string;
  layout: "board" | "table";
  groupBy?: "status" | "severity" | "area";
  filters?: Partial<Record<"status" | "severity" | "area" | "type" | "isolatedFix", string>>;
  sort?: { field: string; dir: "asc" | "desc" };
};

export const VIEW_PRESETS: ViewPreset[] = [
  { id: "board-status", name: "Board by Status", layout: "board", groupBy: "status" },
  { id: "board-severity", name: "Board by Severity", layout: "board", groupBy: "severity" },
  { id: "board-area", name: "By Area", layout: "board", groupBy: "area" },
  { id: "table-all", name: "All issues", layout: "table", sort: { field: "id", dir: "desc" } },
  {
    id: "table-p0p1",
    name: "🔥 P0 + P1",
    layout: "table",
    sort: { field: "severity", dir: "asc" },
  },
  {
    id: "board-p0-area",
    name: "🚨 P0s by Area",
    layout: "board",
    groupBy: "area",
    filters: { severity: "P0" },
  },
  {
    id: "table-money",
    name: "💰 Money loss",
    layout: "table",
    filters: { type: "Bug / Money loss" },
    sort: { field: "severity", dir: "asc" },
  },
  {
    id: "board-isolated",
    name: "🟢 Ship Now — Isolated",
    layout: "board",
    groupBy: "area",
    filters: { isolatedFix: "true" },
    sort: { field: "severity", dir: "asc" },
  },
];
