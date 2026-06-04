import { AREAS, SEVERITIES, STATUSES, TYPES } from "./constants";

// Whitelist + light validation for incoming issue payloads.
const STRING_FIELDS = ["name", "details", "summary", "file", "suggestedFix", "isolationNotes", "assignee"] as const;

const ENUM_FIELDS: Record<string, readonly string[]> = {
  status: STATUSES,
  severity: SEVERITIES,
  area: AREAS,
  type: TYPES,
};

export type IssueInput = Record<string, unknown>;

export function sanitizeIssue(body: IssueInput, { partial }: { partial: boolean }) {
  const data: Record<string, unknown> = {};

  for (const f of STRING_FIELDS) {
    if (f in body) {
      const v = body[f];
      data[f] = v == null || v === "" ? (f === "name" ? "" : null) : String(v);
    }
  }

  for (const [f, allowed] of Object.entries(ENUM_FIELDS)) {
    if (f in body) {
      const v = body[f];
      if (v == null || v === "") {
        data[f] = f === "status" ? "Backlog" : null;
      } else if (allowed.includes(String(v))) {
        data[f] = String(v);
      } else {
        throw new Error(`Invalid value for ${f}: ${v}`);
      }
    }
  }

  if ("isolatedFix" in body) data.isolatedFix = Boolean(body.isolatedFix);
  if ("boardOrder" in body && typeof body.boardOrder === "number") data.boardOrder = body.boardOrder;

  if (!partial) {
    if (!data.name || String(data.name).trim() === "") throw new Error("Name is required");
    if (!("status" in data)) data.status = "Backlog";
  }

  return data;
}
