import * as React from "react";

/** Capsule search field with optional scope chip and a clear affordance. */
export interface SearchFieldProps extends React.HTMLAttributes<HTMLSpanElement> {
  value?: string;
  onChange?: React.ChangeEventHandler<HTMLInputElement>;
  onClear?: () => void;
  placeholder?: string;
  width?: number | string;
  size?: "regular" | "large";
  /** Small leading chip, e.g. "This session". */
  scope?: React.ReactNode;
}

export function SearchField(props: SearchFieldProps): JSX.Element;
