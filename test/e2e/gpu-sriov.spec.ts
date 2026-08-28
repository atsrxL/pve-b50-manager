import { test, expect } from '@playwright/test';
import { openGpuTab, openModifyVfsDialog } from './helpers';

test.describe('SR-IOV Management', () => {

    test('modify dialog exposes BMG v3 controls', async ({ page }) => {
        const dialog = await openModifyVfsDialog(page);

        await expect(dialog).toContainText('0000:04:00.0');
        await expect(dialog).toContainText('Max VFs');
        await expect(dialog).toContainText('Scheduler priority');
        await expect(dialog).toContainText('Per-VF resource profiles');
        await page.keyboard.press('Escape');
    });

    test('persist checkbox exists in dialog', async ({ page }) => {
        const dialog = await openModifyVfsDialog(page);

        const persistRow = dialog.locator('.x-form-item', {
            hasText: 'Persist across reboots',
        }).first();
        await expect(persistRow).toBeVisible();
        await expect(persistRow.locator('.x-form-checkbox')).toBeVisible();
        await page.keyboard.press('Escape');
    });

    test('modify VFs dialog has num_vfs field', async ({ page }) => {
        const dialog = await openModifyVfsDialog(page);

        const numField = dialog.locator('input[name="num_vfs"]');
        await expect(numField).toBeVisible({ timeout: 5000 });
        await expect(numField).toHaveValue('0');
        await page.keyboard.press('Escape');
    });

    test('zero-VF fixture exposes remove action without applying it', async ({ page }) => {
        const dialog = await openModifyVfsDialog(page);

        await expect(dialog.locator('.x-btn-inner:text-is("Remove all VFs")')).toBeVisible();
        await page.keyboard.press('Escape');
    });
});
