import * as React from "react";

/** One row of a source list, outline or message list. Selection uses the accent fill. */
export interface ListRowProps extends React.HTMLAttributes<HTMLDivElement> {
  title?: React.ReactNode;
  subtitle?: React.ReactNode;
  leading?: React.ReactNode;
  trailing?: React.ReactNode;
  selected?: boolean;
  /** true = expanded, false = collapsed, undefined = no triangle. */
  disclosure?: boolean;
  /** Outline indent level. */
  depth?: number;
  size?: "compact" | "regular";
}

export function ListRow(props: ListRowProps): JSX.Element;
