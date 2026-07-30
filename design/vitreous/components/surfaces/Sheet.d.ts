import * as React from "react";

/** Modal that belongs to a window; drops from the titlebar. Parent needs `position: relative`. */
export interface SheetProps extends React.HTMLAttributes<HTMLDivElement> {
  open?: boolean;
  title?: React.ReactNode;
  message?: React.ReactNode;
  icon?: React.ReactNode;
  actions?: React.ReactNode;
  width?: number | string;
  onDismiss?: () => void;
  children?: React.ReactNode;
}

export function Sheet(props: SheetProps): JSX.Element | null;
