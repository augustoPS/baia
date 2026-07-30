import * as React from "react";

/**
 * Standard control. `push` is the neutral default, `accent` is the single default
 * action per window, `glass` is for buttons that float over content (toolbars,
 * media overlays), `borderless` for inline/table actions.
 * @startingPoint section="Controls" subtitle="Push, accent, glass, borderless, destructive" viewport="700x150"
 */
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "push" | "accent" | "glass" | "borderless" | "destructive";
  size?: "small" | "regular" | "large" | "prominent";
  shape?: "rounded" | "capsule";
  fullWidth?: boolean;
  /** Rendered as a dimmed key hint, e.g. "⌘S". */
  keyEquivalent?: string;
  disabled?: boolean;
}

export function Button(props: ButtonProps): JSX.Element;
