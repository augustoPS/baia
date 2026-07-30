import * as React from "react";

/** Centered app-modal alert with a tinted severity glyph. */
export interface AlertProps extends React.HTMLAttributes<HTMLDivElement> {
  open?: boolean;
  severity?: "info" | "warning" | "error" | "success";
  title?: React.ReactNode;
  message?: React.ReactNode;
  actions?: React.ReactNode;
  onDismiss?: () => void;
  width?: number | string;
}

export function Alert(props: AlertProps): JSX.Element | null;
