import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Scopa Board",
  description: "In-house bug & issue tracker",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
