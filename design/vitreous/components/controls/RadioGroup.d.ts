import * as React from "react";

export interface RadioItem { id: string; label: React.ReactNode; description?: React.ReactNode }

/** Exclusive choice where each option needs a sentence of explanation. */
export interface RadioGroupProps extends React.HTMLAttributes<HTMLDivElement> {
  items?: Array<string | RadioItem>;
  value?: string;
  onChange?: (id: string) => void;
  orientation?: "vertical" | "horizontal";
  name?: string;
  disabled?: boolean;
}

export function RadioGroup(props: RadioGroupProps): JSX.Element;
