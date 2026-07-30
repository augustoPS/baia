import * as React from "react";

/** Compact process state for list rows, tabs and status bars. */
export interface StatusDotProps extends React.HTMLAttributes<HTMLSpanElement> {
  tone?: "running" | "ok" | "warn" | "error" | "idle";
  pulse?: boolean;
  label?: React.ReactNode;
  size?: number;
}

export function StatusDot(props: StatusDotProps): JSX.Element;
