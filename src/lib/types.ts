export type Issue = {
  id: number;
  name: string;
  status: string;
  severity: string | null;
  area: string | null;
  type: string | null;
  details: string | null;
  summary: string | null;
  file: string | null;
  suggestedFix: string | null;
  isolatedFix: boolean;
  isolationNotes: string | null;
  assignee: string | null;
  boardOrder: number;
  createdAt: string;
  updatedAt: string;
  _count?: { comments: number };
};

export type Comment = {
  id: number;
  issueId: number;
  author: string | null;
  body: string;
  createdAt: string;
};
