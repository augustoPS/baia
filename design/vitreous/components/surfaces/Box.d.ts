import * as React from "react";

/** Titled content group inside a window (the NSBox role). */
export interface BoxProps extends React.HTMLAttributes<HTMLElement> {
  title?: React.ReactNode;
  subtitle?: React.ReactNode;
  header?: React.ReactNode;
  footer?: React.ReactNode;
  actions?: React.ReactNode;
  material?: "ultraThin" | "thin" | "regular";
  pad?: string | number;
  radius?: string;
  children?: React.ReactNode;
}

export function Box(props: BoxProps): JSX.Element;
