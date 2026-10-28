import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';

export const baseOptions: BaseLayoutProps = {
  nav: { title: <span className="font-mono font-semibold tracking-tight">grpc-lite</span> },
  githubUrl: 'https://github.com/fanyang89/grpc-lite',
  links: [{ text: 'Documentation', url: '/docs', active: 'nested-url' }],
};
