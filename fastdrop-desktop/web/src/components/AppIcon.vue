<script setup lang="ts">
defineProps<{
  name: string
  size?: number
}>()
</script>

<template>
  <svg
    class="app-icon"
    :width="size || 20"
    :height="size || 20"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.8"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <template v-if="name === 'home'">
      <path d="m3 10 9-7 9 7"/><path d="M5 9v11h14V9"/><path d="M9 20v-6h6v6"/>
    </template>
    <template v-else-if="name === 'history'">
      <path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>
    </template>
    <template v-else-if="name === 'inbox'">
      <path d="M4 4h16v16H4z"/><path d="M4 14h4l2 3h4l2-3h4"/>
    </template>
    <template v-else-if="name === 'settings'">
      <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1A1.7 1.7 0 0 0 9 4.6 1.7 1.7 0 0 0 10 3v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/>
    </template>
    <template v-else-if="name === 'upload'">
      <path d="M12 16V4"/><path d="m7 9 5-5 5 5"/><path d="M5 15v5h14v-5"/>
    </template>
    <template v-else-if="name === 'folder'">
      <path d="M3 6h7l2 2h9v11H3z"/>
    </template>
    <template v-else-if="name === 'phone'">
      <rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>
    </template>
    <template v-else-if="name === 'computer'">
      <rect x="3" y="3" width="18" height="13" rx="2"/><path d="M8 21h8M12 16v5"/>
    </template>
    <template v-else-if="name === 'plus'">
      <path d="M12 5v14M5 12h14"/>
    </template>
    <template v-else-if="name === 'qr'">
      <path d="M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h3v3h-3zM18 18h3v3h-3zM18 14h3M14 19v2"/>
    </template>
    <template v-else-if="name === 'wifi'">
      <path d="M5 12.5a10 10 0 0 1 14 0M8 16a6 6 0 0 1 8 0"/><circle cx="12" cy="20" r="1" fill="currentColor" stroke="none"/>
    </template>
    <template v-else-if="name === 'pause'">
      <path d="M9 5v14M15 5v14"/>
    </template>
    <template v-else-if="name === 'play'">
      <path d="m8 5 11 7-11 7z"/>
    </template>
    <template v-else-if="name === 'x'">
      <path d="m6 6 12 12M18 6 6 18"/>
    </template>
    <template v-else-if="name === 'check'">
      <path d="m5 12 4 4L19 6"/>
    </template>
    <template v-else-if="name === 'refresh'">
      <path d="M20 6v5h-5M4 18v-5h5"/><path d="M6.1 9a7 7 0 0 1 11.7-2.6L20 11M4 13l2.2 4.6A7 7 0 0 0 17.9 15"/>
    </template>
    <template v-else-if="name === 'copy'">
      <rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>
    </template>
    <template v-else-if="name === 'file'">
      <path d="M6 2h8l4 4v16H6z"/><path d="M14 2v5h5"/>
    </template>
    <template v-else-if="name === 'shield'">
      <path d="M12 22s8-4 8-11V5l-8-3-8 3v6c0 7 8 11 8 11Z"/><path d="m9 12 2 2 4-4"/>
    </template>
    <template v-else>
      <circle cx="12" cy="12" r="9"/>
    </template>
  </svg>
</template>

<style scoped>
.app-icon { display: block; flex: 0 0 auto; }
</style>
