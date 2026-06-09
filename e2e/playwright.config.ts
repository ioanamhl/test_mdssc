import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  retries: 2,
  timeout: 30000,
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3002',
    headless: true,
  },
  reporter: [['html', { outputFolder: 'playwright-report', open: 'never' }]],
});
