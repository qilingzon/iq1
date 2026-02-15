interface Locale {
    [key: string]: string;
}
import nl from '@locales/nl.json';
import en from '@locales/en.json';
import de from '@locales/de.json';
import es from '@locales/es.json';
import hr from '@locales/hr.json';
import fr from '@locales/fr.json';
import zh from '@locales/zh.json';

const translations: Record<string, Locale>  = {
    en: en,
    nl: nl,
    zh: zh,
    es: es,
    de: de,
    hr: hr,
    fr: fr,
};

let runtimeLang: string | undefined = undefined;

function getDefaultLang(): string {
    if (typeof document !== 'undefined' && document.documentElement && document.documentElement.lang) {
        return document.documentElement.lang;
    }
    // fall back to build-time env if available
    // @ts-ignore
    if (typeof import_meta !== 'undefined' && import_meta.env && import_meta.env.WEBSITE_LANGUAGE) {
        // @ts-ignore
        return import_meta.env.WEBSITE_LANGUAGE;
    }
    // @ts-ignore
    return (import.meta && import.meta.env && import.meta.env.WEBSITE_LANGUAGE) || 'zh';
}

export function setLanguage(l: string) {
    runtimeLang = l;
    if (typeof document !== 'undefined' && document.documentElement) {
        document.documentElement.lang = l;
    }
}

export function getLanguage(): string {
    return runtimeLang || getDefaultLang();
}

export const t = (field: string): string => {
    const lang = getLanguage();

    if (translations[lang] && translations[lang][field]) {
        return translations[lang][field];
    }

    if (translations['en'] && translations['en'][field]) {
        return translations['en'][field];
    }

    return field;
};