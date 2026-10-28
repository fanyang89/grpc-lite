import { createMDX } from 'fumadocs-mdx/next';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const withMDX = createMDX();

export default withMDX({
  output: 'export',
  basePath: '/grpc-lite',
  trailingSlash: true,
  images: { unoptimized: true },
  turbopack: { root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..') },
});
