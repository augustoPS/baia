import * as React from "react";

/** Single keyboard glyph cap — build shortcuts by placing several in a row. */
export interface KeyCapProps extends React.HTMLAttributes<HTMLElement> {
  size?: "small" | "regular";
  children?: React.ReactNode;
}

export function KeyCap(props: KeyCapProps): JSX.Element;
