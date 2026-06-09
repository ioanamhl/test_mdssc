import { test, expect } from '@playwright/test';

test('frontend homepage loads', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('body')).toBeVisible();
  await expect(page).not.toHaveTitle('');
});

test('backend API responds', async ({ request }) => {
  const baseUrl = process.env.BASE_URL || 'http://localhost:3002';
  const backendUrl = baseUrl.replace(/:\d+$/, ':3001');
  const response = await request.get(backendUrl);
  expect(response.status()).toBeLessThan(500);
});
