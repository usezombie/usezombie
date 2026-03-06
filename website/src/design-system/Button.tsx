import { type ComponentProps, type ReactNode } from "react";
import { Link } from "react-router-dom";

type Variant = "primary" | "ghost" | "double-border";

type BaseProps = {
  variant?: Variant;
  children: ReactNode;
};

type LinkButtonProps = BaseProps & {
  to: string;
  external?: boolean;
} & Omit<ComponentProps<"a">, "href">;

type NativeButtonProps = BaseProps & ComponentProps<"button">;

export type ButtonProps = LinkButtonProps | NativeButtonProps;

function isLink(props: ButtonProps): props is LinkButtonProps {
  return "to" in props;
}

function classNames(variant: Variant): string {
  const base = "z-btn";
  if (variant === "ghost") return `${base} z-btn--ghost`;
  if (variant === "double-border") return `${base} z-btn--double`;
  return base;
}

export default function Button(props: ButtonProps) {
  const variant = props.variant ?? "primary";
  const cls = classNames(variant);

  if (isLink(props)) {
    const { to, external, variant: _, children, ...rest } = props;
    if (external || to.startsWith("http") || to.startsWith("mailto:")) {
      return (
        <a className={cls} href={to} target={external ? "_blank" : undefined} rel={external ? "noopener noreferrer" : undefined} {...rest}>
          {children}
        </a>
      );
    }
    return (
      <Link className={cls} to={to} {...(rest as Omit<ComponentProps<typeof Link>, "to" | "className">)}>
        {children}
      </Link>
    );
  }

  const { variant: _, children, ...rest } = props;
  return (
    <button className={cls} type="button" {...rest}>
      {children}
    </button>
  );
}
