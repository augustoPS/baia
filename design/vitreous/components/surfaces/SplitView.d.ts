import * as React from "react";

export interface SplitPane {
  id?: string;
  /** CSS grid track: "var(--w-sidebar)", "minmax(0,1fr)", "300px". */
  width?: string;
  content?: React.ReactNode;
  scroll?: boolean;
}

/** Horizontal pane splitter with hairline dividers — the window body layout. */
export interface SplitViewProps extends React.HTMLAttributes<HTMLDivElement> {
  panes?: SplitPane[];
  gap?: number | string;
  dividers?: boolean;
}

export function SplitView(props: SplitViewProps): JSX.Element;
