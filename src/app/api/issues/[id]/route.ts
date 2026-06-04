import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { sanitizeIssue } from "@/lib/issues";

export const dynamic = "force-dynamic";

function parseId(params: { id: string }) {
  const id = Number(params.id);
  if (!Number.isInteger(id)) throw new Error("Invalid id");
  return id;
}

// GET /api/issues/:id — one issue with comments.
export async function GET(_req: NextRequest, { params }: { params: { id: string } }) {
  try {
    const id = parseId(params);
    const issue = await prisma.issue.findUnique({
      where: { id },
      include: { comments: { orderBy: { createdAt: "asc" } } },
    });
    if (!issue) return NextResponse.json({ error: "Not found" }, { status: 404 });
    return NextResponse.json(issue);
  } catch (e: any) {
    return NextResponse.json({ error: e.message }, { status: 400 });
  }
}

// PATCH /api/issues/:id — partial update (used for inline edits + drag/drop).
export async function PATCH(req: NextRequest, { params }: { params: { id: string } }) {
  try {
    const id = parseId(params);
    const body = await req.json();
    const data = sanitizeIssue(body, { partial: true });
    const issue = await prisma.issue.update({ where: { id }, data: data as any });
    return NextResponse.json(issue);
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }
}

// DELETE /api/issues/:id
export async function DELETE(_req: NextRequest, { params }: { params: { id: string } }) {
  try {
    const id = parseId(params);
    await prisma.issue.delete({ where: { id } });
    return NextResponse.json({ ok: true });
  } catch (e: any) {
    return NextResponse.json({ error: e.message }, { status: 400 });
  }
}
