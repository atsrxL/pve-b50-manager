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

    test('device information button opens properties', async ({ page }) => {
        await openGpuTab(page);

        const infoButton = page.locator('.pve-gpu-device-info').first();
        await expect(infoButton).toBeVisible({ timeout: 10000 });
        await infoButton.click();

        const dialog = page.locator('.x-window:has-text("Device Properties")').last();
        await expect(dialog).toBeVisible({ timeout: 5000 });
        await expect(dialog).toContainText('0000:04:00.0');
        await expect(dialog).toContainText('0x8086');
        await expect(dialog).toContainText('bmg');
    });

    test('ATS safety policy is visible for the selected BMG BDF', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        const atsButton = page.locator('.x-btn:has(.x-btn-inner:text-is("ATS Policy"))').first();
        await expect(atsButton).toBeEnabled({ timeout: 10000 });
        await atsButton.click();
        const atsPanel = page.locator('.x-window:has-text("ATS Safety Policy")').last();
        await expect(atsPanel).toBeVisible({ timeout: 10000 });
        await expect(atsPanel).toContainText('Active:');
        await expect(atsPanel).toContainText('Persistent:');
        await expect(atsPanel).toContainText('ATS:');
        await expect(atsPanel).toContainText('Managed:');
    });

    test('ATS safety gate explains unsafe or unknown whole-GPU writes', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        const atsButton = page.locator('.x-btn:has(.x-btn-inner:text-is("ATS Policy"))').first();
        await expect(atsButton).toBeEnabled({ timeout: 10000 });
        await atsButton.click();
        const atsPanel = page.locator('.x-window:has-text("ATS Safety Policy")').last();
        await expect(atsPanel).toBeVisible({ timeout: 10000 });

        const button = page.locator(
            '.x-btn:has(.x-btn-inner:text-is("Quick Whole-GPU Passthrough"))'
        ).first();
        const panelText = await atsPanel.textContent();
        const unsafeOrUnknown = /ATS unsafe|ATS policy status is unknown/.test(panelText || '');
        if (unsafeOrUnknown) {
            await expect(button).toBeDisabled({ timeout: 10000 });
            await expect(atsPanel).toContainText(/IOTLB_INV_TIMEOUT|native status view/);
        } else {
            await expect(button).toBeEnabled({ timeout: 10000 });
        }
    });

    test('device grid carries telemetry and LMEM without a duplicate detail panel', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        await expect(page.getByText('LMEM / VRAM', { exact: true })).toBeVisible({ timeout: 5000 });
        await expect(page.getByText('43°C', { exact: true })).toBeVisible({ timeout: 5000 });
        await expect(page.getByText('Telemetry', { exact: true })).toHaveCount(0);
        await expect(page.getByText('Device Detail', { exact: true })).toHaveCount(0);
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
        await expect(page.getByText('LMEM', { exact: true }).last()).toBeVisible({ timeout: 5000 });
        await expect(page.getByText('VF #', { exact: true })).toBeVisible({ timeout: 5000 });
    });

    test('whole-GPU quick mode explains the full transaction', async ({ page }) => {
        await openGpuTab(page);

        await page.locator('text=0000:04:00.0').first().click();
        const atsButton = page.locator('.x-btn:has(.x-btn-inner:text-is("ATS Policy"))').first();
        await expect(atsButton).toBeEnabled({ timeout: 10000 });
        await atsButton.click();
        const atsPanel = page.locator('.x-window:has-text("ATS Safety Policy")').last();
        await expect(atsPanel).toBeVisible({ timeout: 10000 });
        const button = page.locator(
            '.x-btn:has(.x-btn-inner:text-is("Quick Whole-GPU Passthrough"))'
        ).first();
        await page.waitForTimeout(1000);
        if (!(await button.isEnabled())) {
            await expect(atsPanel).toContainText(/ATS policy status is unknown|ATS unsafe|native status view/);
            return;
        }
        await button.click();

        const dialog = page.locator('.x-window:has-text("Quick Whole-GPU Passthrough")').last();
        await expect(dialog).toBeVisible({ timeout: 5000 });
        await expect(dialog.getByText('This transaction will:')).toBeVisible();
        await expect(dialog.getByText(/Delete all .* active VF/)).toBeVisible();
        await expect(dialog.getByText(/Bind the physical GPU to vfio-pci/)).toBeVisible();
        await expect(dialog.getByText(/Assign the whole physical GPU/)).toBeVisible();
        await expect(dialog.getByText(/Separate audio or other PCI devices are not moved/)).toBeVisible();
    });
});
