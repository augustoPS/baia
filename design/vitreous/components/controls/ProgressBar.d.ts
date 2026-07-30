import * as React from "react";

/** Determinate or indeterminate progress track. */
export interface ProgressBarProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number;
  indeterminate?: boolean;
  label?: React.ReactNode;
  valueLabel?: React.ReactNode;
  tone?: "accent" | "positive" | "caution" | "negative";
  size?: "small" | "regular";
}

export function ProgressBar(props: ProgressBarProps): JSX.Element;
