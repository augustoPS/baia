import * as React from "react";

/**
 * Recessed text field — glass is a raised material, so inputs read as wells:
 * inner shadow, no outer rim. Focus draws a 1px accent stroke plus a soft ring.
 * @startingPoint section="Controls" subtitle="Fields, search, tokens, steppers" viewport="700x180"
 */
export interface TextFieldProps extends React.InputHTMLAttributes<HTMLInputElement> {
  label?: React.ReactNode;
  hint?: React.ReactNode;
  invalid?: boolean;
  mono?: boolean;
  multiline?: boolean;
  rows?: number;
  size?: "regular" | "large";
  prefix?: React.ReactNode;
  suffix?: React.ReactNode;
  wrapStyle?: React.CSSProperties;
}

export function TextField(props: TextFieldProps): JSX.Element;
