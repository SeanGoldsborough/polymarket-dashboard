import { NextRequest, NextResponse } from "next/server";
import { Prisma } from "@prisma/client";
import { prisma } from "@/lib/db";
import { sanitizeIssue } from "@/lib/issues";

export const dynamic = "force-dynamic";

const INT4_MAX = 2147483647;

function parseId(params: { id: string }): number {
  if (!/^\d+$/.test(params.id)) throw new Error("Invalid id");
  const id = Number(params.id);
  if (id < 1 || id > INT4_MAX) throw new Error("Invalid id");
  return id;
}

// Prisma "record not found" -> clean 404 instead of leaking internals.
function isNotFound(e: unknown): boolean {
  return e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2025";
}

// GET /api/issues/:id — one issue with comments.
export async function GET(_req: NextRequest, { params }: { params: { id: string } }) {
  let id: number;
  try {
    id = parseId(params);
  } catch {
    return NextResponse.json({ error: "Invalid id" }, { status: 400 });
  }
  const issue = await prisma.issue.findUnique({
    where: { id },
    include: { comments: { orderBy: { createdAt: "asc" } } },
  });
  if (!issue) return NextResponse.json({ error: "Not found" }, { status: 404 });
  return NextResponse.json(issue);
}

// PATCH /api/issues/:id — partial update (used for inline edits + drag/drop).
export async function PATCH(req: NextRequest, { params }: { params: { id: string } }) {
  let id: number;
  let data;
  try {
    id = parseId(params);
    data = sanitizeIssue(await req.json(), { partial: true });
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }
  try {
    const issue = await prisma.issue.update({ where: { id }, data });
    return NextResponse.json(issue);
  } catch (e) {
    if (isNotFound(e)) return NextResponse.json({ error: "Not found" }, { status: 404 });
    return NextResponse.json({ error: "Update failed" }, { status: 500 });
  }
}

// DELETE /api/issues/:id
export async function DELETE(_req: NextRequest, { params }: { params: { id: string } }) {
  let id: number;
  try {
    id = parseId(params);
  } catch {
    return NextResponse.json({ error: "Invalid id" }, { status: 400 });
  }
  try {
    await prisma.issue.delete({ where: { id } });
    return NextResponse.json({ ok: true });
  } catch (e) {
    if (isNotFound(e)) return NextResponse.json({ error: "Not found" }, { status: 404 });
    return NextResponse.json({ error: "Delete failed" }, { status: 500 });
  }
}
