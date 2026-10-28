# grpc-lite documentation site

Fumadocs and Next.js render the Markdown in `../docs` as a static site.
The deployment URL is <https://fanyang89.github.io/grpc-lite/>.

## Local development

Use Node.js 22 and npm:

```sh
cd website
npm ci
npm run dev
```

Open <http://localhost:3000/grpc-lite/>. Edit content in `docs/` and navigation
in `docs/meta.json`. Each page has `title` and `description` frontmatter and a
single Markdown H1. Ordinary repository-relative links work in GitHub and are
rewritten at build time: documentation links stay on the site, while source,
test, and evidence links point to GitHub. Missing local targets fail the build.
Only user documentation belongs in `docs/`. Maintainer workflows, historical records,
and evidence live in `development/`, outside the page and search content source.
Evidence bundles remain on GitHub, including their original checksummed files.

## Validation and deployment

```sh
npm run typecheck
npm run build
```

The output is `website/out/`. Search uses a prebuilt index at
`/grpc-lite/api/search`; it runs entirely in the browser.

In the GitHub repository, select **Settings → Pages → Build and deployment →
Source → GitHub Actions**. The Documentation workflow validates pull requests
and deploys documentation changes on `main`. It can also be run manually on
`main`. The repository's `mise run check` must pass before pushing.

The site uses `/grpc-lite` as its base path. If moving to a custom domain,
update both `next.config.mjs` and the search index URL in `components/search.tsx`.
