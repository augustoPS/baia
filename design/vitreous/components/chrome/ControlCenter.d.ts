import * as React from "react";

export interface ControlTile {
  id?: string;
  label: React.ReactNode;
  detail?: React.ReactNode;
  /** Toggle state. */
  on?: boolean;
  onToggle?: () => void;
  /** 0–100 renders a slider tile instead of a toggle tile. */
  value?: number;
  /** Grid span out of 4 columns (default 2). */
  span?: number;
}

/** Control Center panel: 4-column tile grid on a thick glass material. */
export interface ControlCenterProps extends React.HTMLAttributes<HTMLDivElement> {
  tiles?: ControlTile[];
  width?: number | string;
}

export function ControlCenter(props: ControlCenterProps): JSX.Element;
