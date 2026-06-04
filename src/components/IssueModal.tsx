"use client";

import { useEffect, useState } from "react";
import type { Comment, Issue } from "@/lib/types";
import { AREAS, SEVERITIES, STATUSES, TYPES, issueKey } from "@/lib/constants";

type FormState = {
  name: string;
  summary: string;
  details: string;
  status: string;
  severity: string;
  area: string;
  type: string;
  file: string;
  suggestedFix: string;
  isolationNotes: string;
  assignee: string;
  isolatedFix: boolean;
};

function toForm(issue: Issue | null): FormState {
  return {
    name: issue?.name ?? "",
    summary: issue?.summary ?? "",
    details: issue?.details ?? "",
    status: issue?.status ?? "Backlog",
    severity: issue?.severity ?? "",
    area: issue?.area ?? "",
    type: issue?.type ?? "",
    file: issue?.file ?? "",
    suggestedFix: issue?.suggestedFix ?? "",
    isolationNotes: issue?.isolationNotes ?? "",
    assignee: issue?.assignee ?? "",
    isolatedFix: issue?.isolatedFix ?? false,
  };
}

function Select({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: readonly string[];
  onChange: (v: string) => void;
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs text-muted">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-full rounded-md border border-border bg-panel2 px-2.5 py-1.5 text-sm outline-none focus:border-zinc-500"
      >
        <option value="">—</option>
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    </label>
  );
}

function Field({
  label,
  value,
  onChange,
  textarea,
  mono,
  placeholder,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  textarea?: boolean;
  mono?: boolean;
  placeholder?: string;
}) {
  const cls = `w-full rounded-md border border-border bg-panel2 px-2.5 py-1.5 text-sm outline-none focus:border-zinc-500 ${
    mono ? "font-mono text-xs" : ""
  }`;
  return (
    <label className="block">
      <span className="mb-1 block text-xs text-muted">{label}</span>
      {textarea ? (
        <textarea value={value} onChange={(e) => onChange(e.target.value)} rows={3} className={cls} placeholder={placeholder} />
      ) : (
        <input value={value} onChange={(e) => onChange(e.target.value)} className={cls} placeholder={placeholder} />
      )}
    </label>
  );
}

export default function IssueModal({
  issue,
  onClose,
  onSave,
  onDelete,
}: {
  issue: Issue | null;
  onClose: () => void;
  onSave: (data: Partial<Issue>) => Promise<{ ok: boolean; error?: string }>;
  onDelete?: () => Promise<{ ok: boolean; error?: string }>;
}) {
  const [form, setForm] = useState<FormState>(() => toForm(issue));
  const [comments, setComments] = useState<Comment[]>([]);
  const [newComment, setNewComment] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const isNew = !issue;

  const set = <K extends keyof FormState>(k: K, v: FormState[K]) =>
    setForm((f) => ({ ...f, [k]: v }));

  useEffect(() => {
    if (!issue) return;
    fetch(`/api/issues/${issue.id}`)
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d?.comments && setComments(d.comments))
      .catch(() => {});
  }, [issue]);

  async function addComment() {
    if (!issue || !newComment.trim()) return;
    const res = await fetch(`/api/issues/${issue.id}/comments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body: newComment }),
    });
    if (res.ok) {
      const created = await res.json();
      setComments((c) => [...c, created]);
      setNewComment("");
    }
  }

  async function submit() {
    if (!form.name.trim()) {
      setError("Name is required");
      return;
    }
    setSaving(true);
    setError("");
    const result = await onSave({
      name: form.name.trim(),
      summary: form.summary || null,
      details: form.details || null,
      status: form.status,
      severity: form.severity || null,
      area: form.area || null,
      type: form.type || null,
      file: form.file || null,
      suggestedFix: form.suggestedFix || null,
      isolationNotes: form.isolationNotes || null,
      assignee: form.assignee || null,
      isolatedFix: form.isolatedFix,
    } as Partial<Issue>);
    // On success the parent unmounts this modal; on failure keep it open.
    if (!result.ok) {
      setError(result.error || "Save failed");
      setSaving(false);
    }
  }

  async function handleDelete() {
    if (!onDelete || !confirm("Delete this issue?")) return;
    setSaving(true);
    setError("");
    const result = await onDelete();
    if (!result.ok) {
      setError(result.error || "Delete failed");
      setSaving(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/60 p-4 sm:p-10"
      onClick={onClose}
    >
      <div
        className="w-full max-w-2xl rounded-xl border border-border bg-panel shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* header */}
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <span className="text-xs text-muted">{isNew ? "New issue" : issueKey(issue!.id)}</span>
          <button onClick={onClose} className="text-muted hover:text-white">✕</button>
        </div>

        <div className="max-h-[70vh] space-y-4 overflow-y-auto px-5 py-4">
          <textarea
            value={form.name}
            onChange={(e) => set("name", e.target.value)}
            placeholder="Issue title…"
            rows={2}
            className="w-full resize-none rounded-md border border-transparent bg-transparent text-lg font-medium outline-none focus:border-border focus:bg-panel2 focus:px-2.5 focus:py-1.5"
          />

          <div className="grid grid-cols-2 gap-3">
            <Select label="Status" value={form.status} options={STATUSES} onChange={(v) => set("status", v || "Backlog")} />
            <Select label="Severity" value={form.severity} options={SEVERITIES} onChange={(v) => set("severity", v)} />
            <Select label="Area" value={form.area} options={AREAS} onChange={(v) => set("area", v)} />
            <Select label="Type" value={form.type} options={TYPES} onChange={(v) => set("type", v)} />
          </div>

          <Field label="Summary" value={form.summary} onChange={(v) => set("summary", v)} />
          <Field label="Details" value={form.details} onChange={(v) => set("details", v)} textarea />
          <Field label="File" value={form.file} onChange={(v) => set("file", v)} mono placeholder="path/to/file.ts" />
          <Field label="Suggested fix" value={form.suggestedFix} onChange={(v) => set("suggestedFix", v)} textarea />

          <div className="flex items-center gap-2">
            <input
              id="isolated"
              type="checkbox"
              checked={form.isolatedFix}
              onChange={(e) => set("isolatedFix", e.target.checked)}
              className="h-4 w-4"
            />
            <label htmlFor="isolated" className="text-sm">🟢 Isolated fix (safe to ship independently)</label>
          </div>
          {form.isolatedFix && (
            <Field label="Isolation notes" value={form.isolationNotes} onChange={(v) => set("isolationNotes", v)} textarea />
          )}
          <Field label="Assignee" value={form.assignee} onChange={(v) => set("assignee", v)} placeholder="name" />

          {/* comments */}
          {!isNew && (
            <div className="border-t border-border pt-4">
              <div className="mb-2 text-xs text-muted">Comments</div>
              <div className="space-y-2">
                {comments.map((c) => (
                  <div key={c.id} className="rounded-md bg-panel2 px-3 py-2 text-sm">
                    <div className="mb-0.5 text-xs text-muted">
                      {c.author ? `@${c.author}` : "anon"} · {new Date(c.createdAt).toLocaleString()}
                    </div>
                    <div className="whitespace-pre-wrap">{c.body}</div>
                  </div>
                ))}
                {comments.length === 0 && <div className="text-xs text-muted/60">No comments yet.</div>}
              </div>
              <div className="mt-2 flex gap-2">
                <input
                  value={newComment}
                  onChange={(e) => setNewComment(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && addComment()}
                  placeholder="Add a comment…"
                  className="flex-1 rounded-md border border-border bg-panel2 px-2.5 py-1.5 text-sm outline-none focus:border-zinc-500"
                />
                <button onClick={addComment} className="rounded-md bg-panel2 px-3 text-sm hover:bg-border">Post</button>
              </div>
            </div>
          )}
        </div>

        {/* footer */}
        <div className="flex items-center justify-between gap-3 border-t border-border px-5 py-3">
          <div className="flex items-center gap-3">
            {onDelete && (
              <button
                onClick={handleDelete}
                disabled={saving}
                className="rounded-md px-3 py-1.5 text-sm text-red-400 hover:bg-red-500/10 disabled:opacity-50"
              >
                Delete
              </button>
            )}
            {error && <span className="text-sm text-red-400">{error}</span>}
          </div>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              disabled={saving}
              className="rounded-md border border-border px-3 py-1.5 text-sm text-muted hover:bg-panel2 disabled:opacity-50"
            >
              Cancel
            </button>
            <button
              onClick={submit}
              disabled={saving}
              className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500 disabled:opacity-50"
            >
              {saving ? "Saving…" : isNew ? "Create" : "Save"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
