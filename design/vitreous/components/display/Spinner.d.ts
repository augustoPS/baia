import * as React from "react";

/** Small indeterminate activity ring for rows, buttons and toolbars. */
export interface SpinnerProps extends React.HTMLAttributes<HTMLSpanElement> {
  size?: number;
  tone?: "secondary" | "accent";
}

export function Spinner(props: SpinnerProps): JSX.Element;
