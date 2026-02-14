let lang: string | undefined = undefined;
let currency = import.meta.env.CURRENCY;

if (typeof document !== 'undefined' && document.documentElement && document.documentElement.lang) {
    lang = document.documentElement.lang;
} else {
    // fall back to build-time env
    // @ts-ignore
    lang = import.meta && import.meta.env && import.meta.env.WEBSITE_LANGUAGE;
}

if (!lang && typeof document === 'undefined') {
    // During SSR/build time `document` is undefined and env may not be loaded.
    // Fall back to English instead of throwing so the dev server can start.
    // If you prefer, create a `.env` file (or rename `env.txt`) with `WEBSITE_LANGUAGE=zh` or `en`.
    // eslint-disable-next-line no-console
    console.warn('WEBSITE_LANGUAGE not defined during SSR — falling back to "en"');
    lang = 'en';
}

if (!currency) {
    if (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset && document.documentElement.dataset.currency) {
        currency = document.documentElement.dataset.currency;
    } else {
        currency = 'USD';
    }
}

let langCode = 'en-US';
if (lang) {
    if (lang.length === 2) langCode = `${lang}-${lang.toUpperCase()}`;
    if (lang === 'en') langCode = 'en-US';
    if (lang.length === 5) langCode = lang;
}

export function formatTime(time: string): string {
    let startDate = new Date();
    const offset = startDate.getTimezoneOffset();
    const timeArr = time.split(':');
    const BaseTime = `${offset / 60 + parseInt(timeArr[0], 10) / 1}:${timeArr[1]}`;
    let newTime = new Date('1970-01-01T' + BaseTime + 'Z').toLocaleTimeString(langCode, {
        hour: 'numeric',
        minute: 'numeric'
    });

    return newTime;
}

export function formatDate(date: Date): string {
    const newDate = date.toLocaleDateString(langCode, {
        year: 'numeric',
        month: 'short',
        day: 'numeric'
    });

    return newDate;
}

export function formatPrice(price: number): string {
    const formattedPrice = new Intl.NumberFormat(langCode, {
        style: 'currency',
        currency: currency
    }).format(price);

    return formattedPrice.replaceAll(/\s/g, '');
}