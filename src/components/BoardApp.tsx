"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { Issue } from "@/lib/types";
import {
  SEVERITIES,
  VIEW_PRESETS,
  type ViewPreset,
} from "@/lib/constants";
import BoardView from "./BoardView";
import TableView from "./TableView";
import IssueModal from "./IssueModal";

const sevRank = (s: string | null) => (s ? SEVERITIES.indexOf(s as any) : 99);

export default function BoardApp({ initialIssues }: { initialIssues: Issue[] }) {
  const router = useRouter();
  const [issues, setIssues] = useState<Issue[]>(initialIssues);
  const [viewId, setViewId] = useState<string>(VIEW_PRESETS[0].id);
  const [search, setSearch] = useState("");
  const [editing, setEditing] = useState<Issue | null>(null);
  const [creating, setCreating] = useState(false);

  const view: ViewPreset = useMemo(
    () => VIEW_PRESETS.find((v) => v.id === viewId) ?? VIEW_PRESETS[0],
    [viewId],
  );

  // ---- data mutations -------------------------------------------------
  // Optimistically apply `patch`, then reconcile with the server response.
  // On failure, roll back to the exact previous row. Returns success.
  async function patchIssue(id: number, patch: Partial<Issue>): Promise<boolean> {
    const prev = issues.find((i) => i.id === id);
    setIssues((list) => list.map((i) => (i.id === id ? { ...i, ...patch } : i)));
    try {
      const res = await fetch(`/api/issues/${id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch),
      });
      if (!res.ok) throw new Error("patch failed");
      const updated = await res.json();
      setIssues((list) => list.map((i) => (i.id === id ? { ...i, ...updated } : i)));
      return true;
    } catch {
      if (prev) setIssues((list) => list.map((i) => (i.id === id ? prev : i)));
      return false;
    }
  }

  // Returns {ok, error}; the modal stays open and shows the error on failure.
  async function saveIssue(data: Partial<Issue>): Promise<{ ok: boolean; error?: string }> {
    if (creating) {
      const res = await fetch("/api/issues", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      });
      if (!res.ok) {
        const d = await res.json().catch(() => ({}));
        return { ok: false, error: d.error || "Could not create issue" };
      }
      const created = await res.json();
      setIssues((prev) => [{ ...created, _count: { comments: 0 } }, ...prev]);
      setCreating(false);
      return { ok: true };
    }
    if (editing) {
      const ok = await patchIssue(editing.id, data);
      if (!ok) return { ok: false, error: "Save failed — please retry." };
      setEditing(null);
      return { ok: true };
    }
    return { ok: false, error: "Nothing to save" };
  }

  async function deleteIssue(id: number): Promise<{ ok: boolean; error?: string }> {
    const snapshot = issues;
    setIssues((list) => list.filter((i) => i.id !== id));
    const res = await fetch(`/api/issues/${id}`, { method: "DELETE" });
    if (!res.ok) {
      setIssues(snapshot); // restore on failure
      return { ok: false, error: "Delete failed" };
    }
    setEditing(null);
    return { ok: true };
  }

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" });
    router.push("/login");
    router.refresh();
  }

  // ---- filtering + sorting --------------------------------------------
  const filtered = useMemo(() => {
    const f = view.filters ?? {};
    let list = issues.filter((i) => {
      if (f.status && i.status !== f.status) return false;
      if (f.severity && i.severity !== f.severity) return false;
      if (f.area && i.area !== f.area) return false;
      if (f.type && i.type !== f.type) return false;
      if (f.isolatedFix === "true" && !i.isolatedFix) return false;
      if (search.trim()) {
        const q = search.toLowerCase();
        const hay = `${i.name} ${i.summary ?? ""} ${i.file ?? ""} ${i.area ?? ""} ${i.type ?? ""} SCOPAS-${i.id}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });

    // Special case: P0 + P1 preset.
    if (view.id === "table-p0p1") {
      list = list.filter((i) => i.severity === "P0" || i.severity === "P1");
    }

    const sort = view.sort;
    if (sort) {
      list = [...list].sort((a, b) => {
        let cmp = 0;
        if (sort.field === "id") cmp = a.id - b.id;
        else if (sort.field === "severity") cmp = sevRank(a.severity) - sevRank(b.severity);
        else cmp = String((a as any)[sort.field] ?? "").localeCompare(String((b as any)[sort.field] ?? ""));
        return sort.dir === "desc" ? -cmp : cmp;
      });
    }
    return list;
  }, [issues, view, search]);

  return (
    <div className="flex h-screen flex-col">
      {/* Top bar */}
      <header className="flex items-center gap-3 border-b border-border px-4 py-2.5">
        <div className="text-base font-semibold">Scopa Board</div>
        <span className="rounded bg-panel2 px-1.5 py-0.5 text-xs text-muted">
          {issues.length} issues
        </span>
        <div className="ml-2 flex-1">
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search issues…"
            className="w-full max-w-xs rounded-md border border-border bg-panel2 px-3 py-1.5 text-sm outline-none focus:border-zinc-500"
          />
        </div>
        <button
          onClick={() => {
            setCreating(true);
            setEditing(null);
          }}
          className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium hover:bg-blue-500"
        >
          + New issue
        </button>
        <button
          onClick={logout}
          className="rounded-md border border-border px-3 py-1.5 text-sm text-muted hover:bg-panel2"
        >
          Log out
        </button>
      </header>

      {/* View tabs */}
      <nav className="flex items-center gap-1 overflow-x-auto border-b border-border px-3 py-1.5">
        {VIEW_PRESETS.map((v) => (
          <button
            key={v.id}
            onClick={() => setViewId(v.id)}
            className={`whitespace-nowrap rounded-md px-2.5 py-1 text-sm ${
              v.id === viewId ? "bg-panel2 text-white" : "text-muted hover:bg-panel2/60"
            }`}
          >
            {v.name}
          </button>
        ))}
      </nav>

      {/* Content */}
      <main className="min-h-0 flex-1 overflow-auto">
        {view.layout === "board" ? (
          <BoardView
            issues={filtered}
            groupBy={view.groupBy ?? "status"}
            onMove={(id, field, value) => patchIssue(id, { [field]: value } as Partial<Issue>)}
            onOpen={(i) => {
              setEditing(i);
              setCreating(false);
            }}
          />
        ) : (
          <TableView
            issues={filtered}
            onOpen={(i) => {
              setEditing(i);
              setCreating(false);
            }}
          />
        )}
      </main>

      {(editing || creating) && (
        <IssueModal
          key={editing?.id ?? "new"}
          issue={editing}
          onClose={() => {
            setEditing(null);
            setCreating(false);
          }}
          onSave={saveIssue}
          onDelete={editing ? () => deleteIssue(editing.id) : undefined}
        />
      )}
    </div>
  );
}
