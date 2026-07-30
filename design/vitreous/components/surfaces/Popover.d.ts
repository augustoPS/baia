import * as React from "react";

/** Transient panel attached to a control; position it with the parent's layout. */
export interface PopoverProps extends React.HTMLAttributes<HTMLDivElement> {
  open?: boolean;
  /** Which edge the arrow points from. */
  anchor?: "top" | "bottom" | "left" | "right";
  arrow?: boolean;
  width?: number | string;
  pad?: string | number;
  children?: React.ReactNode;
}

export function Popover(props: PopoverProps): JSX.Element | null;
