import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Link from "next/link";
import { Providers } from "./providers";
import { ConnectButton } from "./connect-button";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Looped",
  description: "Automated looping strategies for passive yield",
};

const NAV_LINKS = [
  { href: "/", label: "Dashboard" },
  { href: "/vault", label: "Vault" },
  { href: "/strategies", label: "Strategies" },
  { href: "/calculator", label: "Calculator" },
  { href: "/why", label: "Why Looped?" },
];

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-background text-foreground grain">
        <Providers>
          <nav className="sticky top-0 z-50 flex items-center justify-between px-6 py-3.5 border-b border-border bg-background/80 backdrop-blur-xl">
            <Link href="/" className="flex items-center gap-2.5 group">
              <div className="w-7 h-7 rounded-md bg-accent flex items-center justify-center transition-transform group-hover:scale-105">
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <path
                    d="M7 1v4M7 9v4M1 7h4M9 7h4"
                    stroke="#06070a"
                    strokeWidth="2.5"
                    strokeLinecap="round"
                  />
                </svg>
              </div>
              <span className="text-base font-semibold tracking-tight">
                Looped
              </span>
            </Link>
            <div className="flex items-center gap-1">
              {NAV_LINKS.map((link) => (
                <Link
                  key={link.href}
                  href={link.href}
                  className="px-3 py-1.5 rounded-md text-sm text-muted hover:text-foreground hover:bg-surface-2 transition-all"
                >
                  {link.label}
                </Link>
              ))}
              <div className="ml-2 pl-2 border-l border-border">
                <ConnectButton />
              </div>
            </div>
          </nav>
          <main className="flex-1 flex flex-col">{children}</main>
        </Providers>
      </body>
    </html>
  );
}
