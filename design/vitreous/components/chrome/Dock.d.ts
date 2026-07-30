import * as React from "react";

export interface DockItem {
  id?: string;
  label?: string;
  /** 1–2 letters standing in for an app icon (no icon set in this system). */
  initials?: string;
  /** CSS background for the tile. */
  tint?: string;
  running?: boolean;
}

/** Floating desktop dock with magnification on hover. */
export interface DockProps extends React.HTMLAttributes<HTMLDivElement> {
  items?: DockItem[];
}

export function Dock(props: DockProps): JSX.Element;
