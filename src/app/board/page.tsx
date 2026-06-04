import { prisma } from "@/lib/db";
import BoardApp from "@/components/BoardApp";
import type { Issue } from "@/lib/types";

export const dynamic = "force-dynamic";

export default async function BoardPage() {
  const rows = await prisma.issue.findMany({
    orderBy: [{ id: "desc" }],
    include: { _count: { select: { comments: true } } },
  });
  // Serialize Dates to strings for the client component.
  const issues: Issue[] = rows.map((r) => ({
    ...r,
    createdAt: r.createdAt.toISOString(),
    updatedAt: r.updatedAt.toISOString(),
  }));

  return <BoardApp initialIssues={issues} />;
}
