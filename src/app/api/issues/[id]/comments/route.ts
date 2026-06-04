import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";

export const dynamic = "force-dynamic";

// POST /api/issues/:id/comments — add a comment.
export async function POST(req: NextRequest, { params }: { params: { id: string } }) {
  if (!/^\d+$/.test(params.id)) {
    return NextResponse.json({ error: "Invalid id" }, { status: 400 });
  }
  const issueId = Number(params.id);

  let body: string;
  let author: string | null;
  try {
    const json = await req.json();
    body = String(json.body ?? "").trim();
    author = json.author ? String(json.author) : null;
    if (!body) throw new Error("Comment body required");
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }

  const exists = await prisma.issue.findUnique({ where: { id: issueId }, select: { id: true } });
  if (!exists) return NextResponse.json({ error: "Not found" }, { status: 404 });

  const comment = await prisma.comment.create({ data: { issueId, body, author } });
  return NextResponse.json(comment, { status: 201 });
}
