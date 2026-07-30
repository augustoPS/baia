import * as React from "react";

/**
 * Transparent desktop menu bar. It has no material of its own — only a faint
 * blur and a text shadow so labels survive over any wallpaper.
 */
export interface MenuBarProps extends React.HTMLAttributes<HTMLDivElement> {
  appName?: React.ReactNode;
  menus?: Array<string | { id?: string; label: React.ReactNode }>;
  /** Right-side status text items (battery, network, agent state…). */
  statusItems?: React.ReactNode[];
  clock?: React.ReactNode;
  /** Id of the open menu, or null. */
  open?: string | null;
  onOpen?: (id: string | null) => void;
}

export function MenuBar(props: MenuBarProps): JSX.Element;
