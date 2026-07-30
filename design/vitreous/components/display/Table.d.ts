import * as React from "react";

export interface TableColumn {
  id: string;
  label: React.ReactNode;
  /** CSS grid track, e.g. "160px" or "1fr". */
  width?: string;
  align?: "left" | "right";
  mono?: boolean;
  secondary?: boolean;
}

/**
 * Sortable data table with a chrome-material header row.
 * @startingPoint section="Display" subtitle="Sortable table with selection" viewport="700x260"
 */
export interface TableProps extends React.HTMLAttributes<HTMLDivElement> {
  columns?: TableColumn[];
  rows?: Array<Record<string, any> & { id?: string | number }>;
  selected?: string | number;
  onSelect?: (id: string | number) => void;
  sort?: { id: string; dir: "asc" | "desc" };
  onSort?: (id: string) => void;
  rowHeight?: string;
  zebra?: boolean;
}

export function Table(props: TableProps): JSX.Element;
