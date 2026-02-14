<template>
  <select v-model="lang" @change="onChange" class="select-language">
    <option value="en">EN</option>
    <option value="zh">中文</option>
  </select>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { setLanguage } from '@util/translate';

const initial = (typeof document !== 'undefined' && document.documentElement && document.documentElement.lang) ? document.documentElement.lang : (import.meta.env.WEBSITE_LANGUAGE || 'en');
const lang = ref(initial);

function onChange() {
  setLanguage(lang.value);
}
</script>

<style>
.select-language {
  background: transparent;
  border: none;
  color: inherit;
}
</style>
