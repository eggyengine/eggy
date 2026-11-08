// The docs workflow sets SITE_URL and BASE_PATH (the Pages base path plus /<branch>) from
// actions/configure-pages, so a custom domain works without editing this file. DOCS_BRANCH
// points the "Edit this page" links at the branch being published.
import redirects from './redirects.js';

const baseUrl = `${process.env.BASE_PATH ?? '/eggy'}/`.replace(/\/+$/, '/');

/** @type {import('@docusaurus/types').Config} */
export default {
  title: 'Eggy',
  tagline: 'A game engine for Zig',
  url: process.env.SITE_URL ?? 'https://eggyengine.github.io',
  baseUrl,
  favicon: 'img/icon.svg',
  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',
  markdown: { mermaid: true },
  themes: ['@docusaurus/theme-mermaid'],
  plugins: [['@docusaurus/plugin-client-redirects', { redirects }]],
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          editUrl: `https://github.com/eggyengine/eggy/edit/${process.env.DOCS_BRANCH ?? 'main'}/docs/`,
          breadcrumbs: true,
        },
        blog: false,
      },
    ],
  ],
  themeConfig: {
    colorMode: { respectPrefersColorScheme: true },
    docs: { sidebar: { hideable: true, autoCollapseCategories: true } },
    tableOfContents: { maxHeadingLevel: 3 },
    navbar: {
      title: 'Eggy',
      logo: { alt: 'Eggy', src: 'img/icon.svg' },
      items: [
        { to: '/', label: 'Docs', position: 'left' },
        // `zig build docs --prefix docs/static` makes it; the docs workflow does before building.
        { to: 'pathname:///api/', label: 'API reference', position: 'left' },
        { href: 'https://eggyengine.github.io/weeoui/', label: 'Weeoui', position: 'left' },
        { href: 'https://github.com/eggyengine/eggy', label: 'GitHub', position: 'right' },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Learn',
          items: [
            { label: 'Install Eggy', to: '/getting-started/install' },
            { label: 'Your first game', to: '/getting-started/first-game' },
            { label: 'Plugin hooks', to: '/reference/plugin-hooks' },
          ],
        },
        {
          title: 'Eggy',
          items: [
            { label: 'GitHub', href: 'https://github.com/eggyengine/eggy' },
            { label: 'Releases', href: 'https://github.com/eggyengine/eggy/releases' },
            { label: 'Issues', href: 'https://github.com/eggyengine/eggy/issues' },
          ],
        },
      ],
    },
    prism: { additionalLanguages: ['zig', 'bash', 'powershell'] },
  },
};
