import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";

export const dynamic = "force-dynamic";

// POST /api/issues/:id/comments — add a comment.
export async function POST(req: NextRequest, { params }: { params: { id: string } }) {
  try {
    const issueId = Number(params.id);
    if (!Number.isInteger(issueId)) throw new Error("Invalid id");
    const { body, author } = await req.json();
    if (!body || String(body).trim() === "") throw new Error("Comment body required");
    const comment = await prisma.comment.create({
      data: { issueId, body: String(body), author: author ? String(author) : null },
    });
    return NextResponse.json(comment, { status: 201 });
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }
}
