import Link from 'next/link';
import { HomeLayout } from 'fumadocs-ui/layouts/home';
import { baseOptions } from '@/lib/layout.shared';

const features = [
  ['Streaming first', 'Unary, client-streaming, server-streaming, and full-duplex RPCs with bounded backpressure.'],
  ['Explicit by design', 'Allocators, ownership, and deterministic teardown stay in your hands. Protobuf stays optional.'],
  ['Built for integration', 'Native Zig, a stable C ABI, and a focused synchronous C++ facade.'],
];

export default function Home() {
  return (
    <HomeLayout {...baseOptions}>
      <main className="relative mx-auto w-full max-w-6xl px-6 py-20 md:py-32">
        <div aria-hidden className="hero-grid pointer-events-none absolute inset-0 -z-10 opacity-40" />
        <p className="mb-6 font-mono text-sm text-fd-muted-foreground">ZIG / C / C++</p>
        <h1 className="max-w-3xl text-5xl font-semibold tracking-tight md:text-7xl">gRPC. Small core.<br /><span className="text-fd-muted-foreground">Full-duplex.</span></h1>
        <p className="mt-8 max-w-2xl text-lg leading-8 text-fd-muted-foreground">A lightweight, streaming-first runtime built on nghttp2 and libxev. Real HTTP/2, explicit ownership, and the APIs you need.</p>
        <div className="mt-9 flex flex-wrap gap-3">
          <Link href="/docs" className="rounded-full bg-fd-primary px-6 py-3 font-medium text-fd-primary-foreground">Get started →</Link>
          <a href="https://github.com/fanyang89/grpc-lite" className="rounded-full border bg-fd-background px-6 py-3 font-medium">View on GitHub</a>
        </div>
        <div className="mt-24 grid gap-6 md:grid-cols-3">
          {features.map(([title, description]) => (
            <section key={title} className="rounded-2xl border bg-fd-card p-6">
              <h2 className="font-semibold">{title}</h2>
              <p className="mt-3 text-sm leading-6 text-fd-muted-foreground">{description}</p>
            </section>
          ))}
        </div>
        <p className="mt-10 text-sm text-fd-muted-foreground">Linux x86_64 & ARM64 · Optional native Zig TLS · Tested against official grpc-go peers</p>
      </main>
    </HomeLayout>
  );
}
