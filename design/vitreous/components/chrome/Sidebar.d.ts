import * as React from "react";

export interface SidebarItem {
  id: string;
  label: React.ReactNode;
  /** Trailing count/state text. */
  trailing?: React.ReactNode;
  /** Small colored dot color (CSS color or token). */
  marker?: string;
  depth?: number;
}
export interface SidebarGroup { label?: React.ReactNode; items: SidebarItem[] }

/** Source list on the sidebar material, 28px rows, caps group headers. */
export interface SidebarProps extends React.HTMLAttributes<HTMLElement> {
  groups?: SidebarGroup[];
  value?: string;
  onSelect?: (id: string) => void;
  header?: React.ReactNode;
  footer?: React.ReactNode;
  width?: string;
}

export function Sidebar(props: SidebarProps): JSX.Element;
