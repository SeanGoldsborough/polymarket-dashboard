import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { sanitizeIssue } from "@/lib/issues";

export const dynamic = "force-dynamic";

// GET /api/issues — all issues (filtering/sorting happens client-side).
export async function GET() {
  const issues = await prisma.issue.findMany({
    orderBy: [{ id: "desc" }],
    include: { _count: { select: { comments: true } } },
  });
  return NextResponse.json(issues);
}

// POST /api/issues — create a new issue.
export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const data = sanitizeIssue(body, { partial: false });
    const issue = await prisma.issue.create({ data: data as any });
    return NextResponse.json(issue, { status: 201 });
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }
}
