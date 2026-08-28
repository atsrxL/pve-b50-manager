import { test, expect } from '@playwright/test';
import { openGpuTab } from './helpers';

test.describe('GPU Tab', () => {

    test('GPU panel visible in node view', async ({ page }) => {
        await openGpuTab(page);

        // Verify the GPU panel content is visible
        await expect(page.locator('text=GPU').first()).toBeVisible({ timeout: 10000 });
    });

    test('device grid loads with supported BMG GPU', async ({ page }) => {
        await openGpuTab(page);

        await expect(page.locator('text=0000:04:00.0').first()).toBeVisible({ timeout: 10000 });
        await expect(page.locator('text=0xe211').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=0000:03:00.0')).toHaveCount(0);
    });

    test('device detail shows properties', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify detail panel shows device info
        await expect(page.locator('text=0x8086').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=bmg').first()).toBeVisible({ timeout: 5000 });
    });

    test('telemetry displays temperature', async ({ page }) => {
        await openGpuTab(page);

        // Click device
        await page.locator('text=0000:04:00.0').first().click();
        await page.waitForTimeout(2000);

        await expect(page.locator('text=Telemetry').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=43 °C').first()).toBeVisible({ timeout: 5000 });
    });

    test('SR-IOV prechecks section visible', async ({ page }) => {
        await openGpuTab(page);

        // Click device
        await page.locator('text=0000:04:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify SR-IOV prerequisites section
        await expect(page.locator('text=SR-IOV Prerequisites').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=CPU Virtualization').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=IOMMU').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=GPU Driver').first()).toBeVisible({ timeout: 5000 });
        await expect(page.locator('text=Pass').first()).toBeVisible({ timeout: 5000 });
    });

    test('SR-IOV VF section visible', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        await page.waitForTimeout(2000);

        // Verify VF management section
        await expect(page.locator('text=SR-IOV Virtual Functions').first()).toBeVisible({ timeout: 5000 });
    });
});
