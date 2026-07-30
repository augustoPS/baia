import * as React from "react";

/** Immediate-effect toggle (settings rows, Control Center tiles). */
export interface SwitchProps extends React.HTMLAttributes<HTMLLabelElement> {
  checked?: boolean;
  onChange?: React.ChangeEventHandler<HTMLInputElement>;
  label?: React.ReactNode;
  size?: "small" | "regular";
  disabled?: boolean;
}

export function Switch(props: SwitchProps): JSX.Element;
