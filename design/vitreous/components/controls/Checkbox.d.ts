import * as React from "react";

/** 14px checkbox with optional description line; supports a mixed state. */
export interface CheckboxProps extends React.HTMLAttributes<HTMLLabelElement> {
  checked?: boolean;
  indeterminate?: boolean;
  onChange?: React.ChangeEventHandler<HTMLInputElement>;
  label?: React.ReactNode;
  description?: React.ReactNode;
  disabled?: boolean;
}

export function Checkbox(props: CheckboxProps): JSX.Element;
