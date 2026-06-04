import { swatchFor } from "@/lib/constants";

export function Chip({
  field,
  value,
  className = "",
}: {
  field: string;
  value: string | null | undefined;
  className?: string;
}) {
  if (!value) return null;
  const sw = swatchFor(field, value);
  return (
    <span
      className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-xs font-medium ${sw.chip} ${className}`}
    >
      <span className={`h-1.5 w-1.5 rounded-full ${sw.dot}`} />
      {value}
    </span>
  );
}
