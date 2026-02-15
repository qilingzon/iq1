import { defineConfig } from "astro/config";
import { astroImageTools } from "astro-imagetools";
import icon from "astro-icon";
import mdx from "@astrojs/mdx";
import m2dx from "astro-m2dx";
import sitemap from "@astrojs/sitemap";
import tailwind from "@astrojs/tailwind";
import rehypeExternalLinks from "rehype-external-links";

import vue from "@astrojs/vue";
/** @type {import('astro-m2dx').Options} */

const m2dxOptions = {
  exportComponents: true,
  unwrapImages: true,
  autoImports: true,
};

// https://astro.build/config
export default defineConfig({
  site: "https://nebulix.unfolding.io",
  integrations: [
    icon(),
    mdx({}),
    sitemap(),
    tailwind(),
    vue({
      appEntrypoint: "/src/pages/_app",
    }),
    astroImageTools,
  ],
  markdown: {
    extendDefaultPlugins: true,
    remarkPlugins: [
      [m2dx, m2dxOptions],
    ],
    rehypePlugins: [
      [
        rehypeExternalLinks,
        {
          rel: ["nofollow"],
          target: ["_blank"],
        },
      ],
    ],
  },
  vite: {
    build: {
      rollupOptions: {
        external: [
          "/_pagefind/pagefind.js",
          "/_pagefind/pagefind-ui.js",
          "/_pagefind/pagefind-ui.css",
        ],
      },
      assetsInlineLimit: 10096,
    },
  },
  build: {
    inlineStylesheets: "always",
  },
  scopedStyleStrategy: "attribute",
  prefetch: {
    defaultStrategy: "viewport",
  },
});
