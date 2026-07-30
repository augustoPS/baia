import * as React from "react";

/** Field whose values become removable capsule tokens (filters, recipients, tags). */
export interface TokenFieldProps extends React.HTMLAttributes<HTMLSpanElement> {
  tokens?: Array<string | { id?: string; label: React.ReactNode }>;
  onAdd?: (value: string) => void;
  onRemove?: (token: any, index: number) => void;
  placeholder?: string;
  label?: React.ReactNode;
  wrapStyle?: React.CSSProperties;
}

export function TokenField(props: TokenFieldProps): JSX.Element;
