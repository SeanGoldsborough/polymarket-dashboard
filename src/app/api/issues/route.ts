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
  let data;
  try {
    data = sanitizeIssue(await req.json(), { partial: false });
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "Bad request" }, { status: 400 });
  }
  try {
    const issue = await prisma.issue.create({ data });
    return NextResponse.json(issue, { status: 201 });
  } catch {
    return NextResponse.json({ error: "Could not create issue" }, { status: 500 });
  }
}
