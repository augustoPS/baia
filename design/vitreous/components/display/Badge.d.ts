import * as React from "react";

/** 16px status label or unread count. `filled` for solid emphasis. */
export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  tone?: "neutral" | "accent" | "positive" | "caution" | "negative";
  mono?: boolean;
  filled?: boolean;
  /** Numeric count — renders solid and pill-minimum-width. */
  count?: number;
  children?: React.ReactNode;
}

export function Badge(props: BadgeProps): JSX.Element;
