import Link from "next/link";

export default function Home() {
  return (
    <div className="flex flex-col flex-1 items-center justify-center px-6">
      <div className="max-w-md text-center">
        <div className="w-14 h-14 rounded-xl bg-accent flex items-center justify-center mx-auto mb-6">
          <svg width="24" height="24" viewBox="0 0 14 14" fill="none">
            <path
              d="M7 1v4M7 9v4M1 7h4M9 7h4"
              stroke="#08090a"
              strokeWidth="2"
              strokeLinecap="round"
            />
          </svg>
        </div>
        <h1 className="text-3xl font-semibold tracking-tight mb-3">Looped</h1>
        <p className="text-muted text-base mb-8 leading-relaxed">
          Automated looping strategies for passive yield. Deposit once, earn
          amplified returns.
        </p>
        <div className="flex gap-3 justify-center">
          <Link
            href="/strategies"
            className="px-5 py-2.5 rounded-lg bg-accent text-background text-sm font-medium hover:bg-accent-dim transition-colors"
          >
            View Strategies
          </Link>
        </div>
      </div>
    </div>
  );
}
