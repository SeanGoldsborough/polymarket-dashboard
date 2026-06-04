"use client";

import type { Issue } from "@/lib/types";
import { issueKey } from "@/lib/constants";
import { Chip } from "./Chip";

export default function TableView({
  issues,
  onOpen,
}: {
  issues: Issue[];
  onOpen: (issue: Issue) => void;
}) {
  return (
    <div className="p-3">
      <table className="w-full border-separate border-spacing-0 text-sm">
        <thead>
          <tr className="text-left text-xs text-muted">
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">ID</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Name</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Severity</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Status</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Area</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Type</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">File</th>
            <th className="sticky top-0 bg-bg px-3 py-2 font-medium">Assignee</th>
          </tr>
        </thead>
        <tbody>
          {issues.map((i) => (
            <tr
              key={i.id}
              onClick={() => onOpen(i)}
              className="cursor-pointer hover:bg-panel2/50"
            >
              <td className="border-b border-border px-3 py-2 text-xs text-muted">{issueKey(i.id)}</td>
              <td className="border-b border-border px-3 py-2">
                <span className="flex items-center gap-1.5">
                  {i.isolatedFix && <span title="Isolated fix">🟢</span>}
                  {i.name}
                </span>
              </td>
              <td className="border-b border-border px-3 py-2"><Chip field="severity" value={i.severity} /></td>
              <td className="border-b border-border px-3 py-2"><Chip field="status" value={i.status} /></td>
              <td className="border-b border-border px-3 py-2"><Chip field="area" value={i.area} /></td>
              <td className="border-b border-border px-3 py-2"><Chip field="type" value={i.type} /></td>
              <td className="border-b border-border px-3 py-2 font-mono text-xs text-muted">{i.file}</td>
              <td className="border-b border-border px-3 py-2 text-muted">{i.assignee ? `@${i.assignee}` : ""}</td>
            </tr>
          ))}
          {issues.length === 0 && (
            <tr>
              <td colSpan={8} className="px-3 py-10 text-center text-muted">No issues match.</td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
