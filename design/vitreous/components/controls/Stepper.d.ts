import * as React from "react";

/** Numeric field plus increment/decrement arrows, platform-sized (22px). */
export interface StepperProps extends React.HTMLAttributes<HTMLSpanElement> {
  value?: number;
  min?: number;
  max?: number;
  step?: number;
  onChange?: (value: number) => void;
  /** Trailing unit inside the field, e.g. "s" or "px". */
  unit?: string;
  width?: number;
}

export function Stepper(props: StepperProps): JSX.Element;
