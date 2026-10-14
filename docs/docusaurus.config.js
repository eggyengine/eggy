// The docs workflow sets SITE_URL and BASE_PATH (the Pages base path plus /<branch>) from
// actions/configure-pages, so a custom domain works without editing this file. DOCS_BRANCH
// points the "Edit this page" links at the branch being published.
const baseUrl = `${process.env.BASE_PATH ?? '/eggy'}/`.replace(/\/+$/, '/');

/** @type {import('@docusaurus/types').Config} */
export default {
  title: 'Eggy',
  tagline: 'A game engine for Zig',
  url: process.env.SITE_URL ?? 'https://eggyengine.github.io',
  baseUrl,
  favicon: 'img/icon.svg',
  onBrokenLinks: 'throw',
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          editUrl: `https://github.com/eggyengine/eggy/edit/${process.env.DOCS_BRANCH ?? 'main'}/docs/`,
        },
        blog: false,
      },
    ],
  ],
  themeConfig: {
    colorMode: { respectPrefersColorScheme: true },
    navbar: {
      title: 'Eggy',
      logo: { alt: 'Eggy', src: 'img/icon.svg' },
      items: [
        { to: '/', label: 'Docs', position: 'left' },
        { href: 'https://eggyengine.github.io/weeoui/', label: 'Weeoui', position: 'left' },
        { href: 'https://github.com/eggyengine/eggy', label: 'GitHub', position: 'right' },
      ],
    },
    prism: { additionalLanguages: ['zig', 'bash'] },
  },
};
