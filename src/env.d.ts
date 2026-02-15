/// <reference path="../.astro/types.d.ts" />
/// <reference types="astro/client" />
/// <reference types="astro-imagetools" />
declare module "astro-imagetools/components"
declare module "astro-imagetools/api"

declare module "*.vue" {
	import type { DefineComponent } from "vue";
	const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, any>;
	export default component;
}

