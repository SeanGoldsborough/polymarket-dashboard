"use client";

import { useState } from "react";
import type { Issue } from "@/lib/types";
import { AREAS, SEVERITIES, STATUSES, issueKey } from "@/lib/constants";
import { Chip } from "./Chip";

type GroupBy = "status" | "severity" | "area";

const COLUMNS: Record<GroupBy, string[]> = {
  status: [...STATUSES],
  severity: [...SEVERITIES],
  area: [...AREAS],
};

const NONE = "__none__";

export default function BoardView({
  issues,
  groupBy,
  onMove,
  onOpen,
}: {
  issues: Issue[];
  groupBy: GroupBy;
  onMove: (id: number, field: GroupBy, value: string | null) => void;
  onOpen: (issue: Issue) => void;
}) {
  const [dragId, setDragId] = useState<number | null>(null);
  const [overCol, setOverCol] = useState<string | null>(null);

  // Group issues, then build the column list so that NO issue is ever hidden:
  // start from the predefined options, append any off-list values present in
  // the data (e.g. a status imported from Notion that isn't in our enum), and
  // finally the "(none)" bucket for empty non-status fields.
  const grouped: Record<string, Issue[]> = {};
  for (const i of issues) {
    const key = (i[groupBy] as string | null) || (groupBy === "status" ? "Backlog" : NONE);
    (grouped[key] ??= []).push(i);
  }

  const baseCols = COLUMNS[groupBy];
  const extraCols = Object.keys(grouped).filter((k) => k !== NONE && !baseCols.includes(k));
  const hasNone = grouped[NONE]?.length > 0;
  const columns = [...baseCols, ...extraCols, ...(hasNone ? [NONE] : [])];
  for (const col of columns) grouped[col] ??= [];

  function drop(col: string) {
    if (dragId == null) return;
    const value = col === NONE ? null : col;
    onMove(dragId, groupBy, value);
    setDragId(null);
    setOverCol(null);
  }

  return (
    <div className="flex h-full gap-3 p-3">
      {columns.map((col) => {
        const items = grouped[col] ?? [];
        const label = col === NONE ? "(none)" : col;
        return (
          <div
            key={col}
            onDragOver={(e) => {
              e.preventDefault();
              setOverCol(col);
            }}
            onDragLeave={() => setOverCol((c) => (c === col ? null : c))}
            onDrop={() => drop(col)}
            className={`flex w-72 shrink-0 flex-col rounded-lg bg-panel/60 ${
              overCol === col ? "drag-over" : ""
            }`}
          >
            <div className="flex items-center justify-between px-3 py-2">
              <div className="flex items-center gap-2">
                <Chip field={groupBy} value={col === NONE ? null : col} />
                {col === NONE && <span className="text-sm text-muted">(none)</span>}
              </div>
              <span className="text-xs text-muted">{items.length}</span>
            </div>
            <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-2 pb-3">
              {items.map((i) => (
                <article
                  key={i.id}
                  draggable
                  onDragStart={() => setDragId(i.id)}
                  onDragEnd={() => setDragId(null)}
                  onClick={() => onOpen(i)}
                  className="cursor-pointer rounded-md border border-border bg-panel2 p-2.5 text-sm hover:border-zinc-600"
                >
                  <div className="mb-1.5 flex items-center justify-between">
                    <span className="text-xs text-muted">{issueKey(i.id)}</span>
                    {i.severity && <Chip field="severity" value={i.severity} />}
                  </div>
                  <div className="mb-2 leading-snug">{i.name}</div>
                  <div className="flex flex-wrap gap-1">
                    {groupBy !== "area" && i.area && <Chip field="area" value={i.area} />}
                    {groupBy !== "status" && <Chip field="status" value={i.status} />}
                    {i.isolatedFix && (
                      <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-xs text-green-300">
                        🟢 isolated
                      </span>
                    )}
                  </div>
                  {(i.assignee || (i._count?.comments ?? 0) > 0) && (
                    <div className="mt-2 flex items-center gap-2 text-xs text-muted">
                      {i.assignee && <span>@{i.assignee}</span>}
                      {(i._count?.comments ?? 0) > 0 && <span>💬 {i._count!.comments}</span>}
                    </div>
                  )}
                </article>
              ))}
              {items.length === 0 && (
                <div className="px-1 py-6 text-center text-xs text-muted/60">Drop here</div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
