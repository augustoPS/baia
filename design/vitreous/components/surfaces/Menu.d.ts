import * as React from "react";

export interface MenuItem {
  label?: React.ReactNode;
  shortcut?: React.ReactNode;
  checked?: boolean;
  disabled?: boolean;
  separator?: boolean;
  header?: React.ReactNode;
  submenu?: boolean;
  id?: string;
}

/** Menu list on the menu material. Pass "-" for a separator. */
export interface MenuProps extends React.HTMLAttributes<HTMLDivElement> {
  items?: Array<MenuItem | "-">;
  onPick?: (item: MenuItem) => void;
  width?: number | string;
}

export function Menu(props: MenuProps): JSX.Element;
