import * as React from "react";

/** Toolbar row for WindowFrame. Compose with ToolbarButton / ToolbarSeparator. */
export interface ToolbarProps extends React.HTMLAttributes<HTMLDivElement> {
  leading?: React.ReactNode;
  trailing?: React.ReactNode;
  children?: React.ReactNode;
}
export function Toolbar(props: ToolbarProps): JSX.Element;

export interface ToolbarButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  label?: React.ReactNode;
  active?: boolean;
  /** Small accent count, e.g. unread or pending. */
  badge?: React.ReactNode;
}
export function ToolbarButton(props: ToolbarButtonProps): JSX.Element;

export function ToolbarSeparator(): JSX.Element;
