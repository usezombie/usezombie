import { type ComponentProps, type ReactNode } from "react";

type Props = {
  featured?: boolean;
  children: ReactNode;
} & ComponentProps<"article">;

export default function Card({ featured, children, className, ...rest }: Props) {
  const cls = ["z-card", featured && "z-card--featured", className].filter(Boolean).join(" ");
  return (
    <article className={cls} {...rest}>
      {children}
    </article>
  );
}
