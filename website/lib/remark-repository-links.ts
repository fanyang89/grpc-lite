import { existsSync, statSync } from 'node:fs';
import path from 'node:path';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

// Keep repository-relative Markdown useful both on GitHub and on the site.
export function remarkRepositoryLinks() {
  const root = path.resolve('..');
  const docs = path.join(root, 'docs');

  return (tree: Root, file: { path: string }) => {
    visit(tree, ['link', 'definition', 'image'], (node) => {
      if (!('url' in node) || !node.url || /^(?:[a-z]+:|\/|#)/i.test(node.url)) return;
      const [, pathname, suffix] = node.url.match(/^([^?#]*)(.*)$/s)!;
      const target = path.resolve(path.dirname(file.path), decodeURIComponent(pathname));
      if (!existsSync(target)) throw new Error(`Broken link in ${file.path}: ${node.url}`);

      const relative = path.relative(docs, target);
      if (!relative.startsWith('..') && !relative.startsWith('evidence/') && /\.mdx?$/.test(relative)) {
        const slug = relative.replace(/\.mdx?$/, '').replace(/(^|\/)index$/, '');
        node.url = `/docs/${slug}${suffix}`;
      } else {
        const kind = statSync(target).isDirectory() ? 'tree' : 'blob';
        node.url = `https://github.com/fanyang89/grpc-lite/${kind}/main/${path.relative(root, target)}${suffix}`;
      }
    });
  };
}
