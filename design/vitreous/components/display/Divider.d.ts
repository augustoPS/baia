import * as React from "react";

/** Hairline separator (0.5px). Optional centered caps label. */
export interface DividerProps extends React.HTMLAttributes<HTMLSpanElement> {
  orientation?: "horizontal" | "vertical";
  /** Horizontal inset in px. */
  inset?: number;
  label?: React.ReactNode;
}

export function Divider(props: DividerProps): JSX.Element;
