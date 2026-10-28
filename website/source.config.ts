import { defineConfig, defineDocs } from 'fumadocs-mdx/config';
import { remarkRepositoryLinks } from './lib/remark-repository-links';

export const docs = defineDocs({
  dir: '../docs',
  docs: { files: ['**/*.{md,mdx}', '!evidence/**'] },
  meta: { files: ['**/meta.json'] },
});

export default defineConfig({
  mdxOptions: {
    remarkPlugins: [remarkRepositoryLinks],
  },
});
