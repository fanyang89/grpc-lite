import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Provider } from './provider';
import './global.css';

export const metadata: Metadata = {
  title: { default: 'grpc-lite', template: '%s | grpc-lite' },
  description: 'A lightweight, streaming-first gRPC runtime for Zig, C, and C++.',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
