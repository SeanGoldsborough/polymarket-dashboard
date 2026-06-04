import type { Prisma } from "@prisma/client";
import { AREAS, SEVERITIES, STATUSES, TYPES } from "./constants";

// Whitelist + light validation for incoming issue payloads. The whitelist
// prevents mass-assignment; enum fields are checked against the allowed sets.
const STRING_FIELDS = ["details", "summary", "file", "suggestedFix", "isolationNotes", "assignee"] as const;

const ENUM_FIELDS: Record<string, readonly string[]> = {
  status: STATUSES,
  severity: SEVERITIES,
  area: AREAS,
  type: TYPES,
};

export type IssueInput = Record<string, unknown>;

export function sanitizeIssue(
  body: IssueInput,
  { partial }: { partial: boolean },
): Prisma.IssueCreateInput {
  const data: Record<string, unknown> = {};

  // Name is required on create, and must not be blanked on update.
  if ("name" in body) {
    const s = body.name == null ? "" : String(body.name).trim();
    if (s === "") throw new Error("Name is required");
    data.name = s;
  } else if (!partial) {
    throw new Error("Name is required");
  }

  for (const f of STRING_FIELDS) {
    if (f in body) {
      const v = body[f];
      data[f] = v == null || v === "" ? null : String(v);
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

  if ("isolatedFix" in body) {
    data.isolatedFix = body.isolatedFix === true || body.isolatedFix === "true";
  }

  if (!partial && !("status" in data)) data.status = "Backlog";

  return data as Prisma.IssueCreateInput;
}
