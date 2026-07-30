import * as React from "react";

/**
 * Pop-up menu button. `pullDown` renders the action-menu form (chevron only,
 * static `label`) instead of the value-selection form (accent chevron pair).
 */
export interface PopUpButtonProps extends React.HTMLAttributes<HTMLSpanElement> {
  options?: Array<string | { value: string; label: React.ReactNode }>;
  value?: string;
  onChange?: (value: string) => void;
  size?: "small" | "regular" | "large";
  width?: number | string;
  pullDown?: boolean;
  /** Static title, pull-down form only. */
  label?: React.ReactNode;
  disabled?: boolean;
}

export function PopUpButton(props: PopUpButtonProps): JSX.Element;
