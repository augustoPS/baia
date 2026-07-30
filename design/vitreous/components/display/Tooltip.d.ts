import * as React from "react";

/** Hover help on a HUD material; wrap the trigger element. */
export interface TooltipProps extends React.HTMLAttributes<HTMLSpanElement> {
  content?: React.ReactNode;
  /** Trailing dimmed shortcut, e.g. "⌘R". */
  shortcut?: React.ReactNode;
  placement?: "top" | "bottom" | "left" | "right";
  children?: React.ReactNode;
}

export function Tooltip(props: TooltipProps): JSX.Element;
