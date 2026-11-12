// Run with GPU_EXTJS_PATH pointing to PVE's ext-all-debug.js and Playwright installed.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');

(async () => {
    const browser = await chromium.launch({ executablePath: process.env.BROWSER_PATH, args: ['--no-sandbox'] });
    try {
        const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.setContent('<html><body></body></html>');
        await page.addScriptTag({ path: process.env.GPU_EXTJS_PATH });
        if (process.env.GPU_EXTJS_CSS_PATH) {
            await page.addStyleTag({ path: process.env.GPU_EXTJS_CSS_PATH });
        }
        await page.evaluate(() => {
            window.gettext = text => text;
            window.Proxmox = { Utils: {} };
            window.PVE = {};
        });
        await page.addScriptTag({ path: path.join(__dirname, '../src/js/pve-gpu-plugin.js') });
        await page.evaluate(() => {
            window.api = { persisted: false, drift: true, fail: false, hold: false, pending: [], gets: 0 };
            window.vf = { vf_index: 1, bdf: '0000:0b:00.1', vmid: null, running: false, resources: {} };
            window.sriovFixture = () => ({
                api_version: 3, sriov_numvfs: 1, sriov_maxvfs: 4,
                capabilities: { vf_vm_assignment: true, per_vf_profiles: true, resources: {}, scheduler: {} },
                persisted_config: { persist: api.persisted ? 1 : 0 },
                drift: { has_drift: api.drift }, assignments: [], vfs: api.omitVfs ? undefined : [vf], prechecks: {},
            });
            Proxmox.Utils.API2Request = req => {
                if (req.method === 'POST') {
                    api.persisted = true; api.drift = false;
                    req.success({ result: { data: {} } });
                } else if (req.url.endsWith('/sriov')) {
                    api.gets++;
                    const reply = () => api.fail ? req.failure({ htmlStatus: 'Read failed' }) : req.success({ result: { data: api.empty ? null : sriovFixture() } });
                    if (api.hold) { api.pending.push(reply); } else { reply(); }
                } else if (req.url.endsWith('/qemu')) {
                    req.success({ result: { data: [{ vmid: 202, name: 'Target', status: 'stopped' }] } });
                } else if (req.url.endsWith('/vf')) {
                    const snapshot = JSON.parse(JSON.stringify(vf));
                    const reply = () => req.success({ result: { data: [snapshot] } });
                    if (api.holdVf) { api.vfReply = reply; } else { reply(); }
                } else { throw new Error('Unexpected API request ' + req.url); }
            };
            window.device = Ext.create('Ext.data.Model', { bdf: '0000:0b:00.0', driver: 'xe', sriov_numvfs: 1, sriov_maxvfs: 4 });
            window.panel = Ext.create('PVE.panel.GpuSriovPanel', {
                renderTo: Ext.getBody(), width: 1300, height: 600, pveSelNode: { data: { node: 'fixture' } },
            });
            panel.loadDevice(device);
        });
        assert.equal(await page.evaluate(() => panel.down('#driftBanner').isVisible()), true);
        await page.evaluate(() => {
            panel.openModifyDialog();
            window.editor = Ext.ComponentQuery.query('pveModifyVfsDialog')[0];
            editor.submitProfiles({ num_vfs: 1, persist: 1 });
        });
        await page.waitForFunction(() => panel.sriovStatus.persisted_config.persist === 1);
        assert.equal(await page.evaluate(() => panel.down('#driftBanner').isVisible()), false);
        assert.equal(await page.evaluate(() => editor.destroyed), true);

        // Exercise the actual throttle boundary, without changing panel internals.
        await page.clock.install();
        const beforePoll = await page.evaluate(() => api.gets);
        await page.evaluate(() => { api.persisted = false; api.drift = true; });
        await page.clock.runFor(14000);
        await page.evaluate(() => panel.refreshLiveTelemetry());
        assert.equal(await page.evaluate(() => api.gets), beforePoll);
        await page.clock.runFor(1001);
        await page.evaluate(() => panel.refreshLiveTelemetry());
        assert.equal(await page.evaluate(() => api.gets), beforePoll + 1);
        assert.equal(await page.evaluate(() => panel.down('#driftBanner').isVisible()), true);
        // Opening assignment revalidates persistence rather than rejecting from the stale snapshot.
        await page.evaluate(() => {
            api.persisted = true; api.drift = false;
            panel.openVfAssignmentDialog(panel.down('#vfGrid').getStore().first());
        });
        await page.waitForFunction(() => Ext.ComponentQuery.query('pveAssignVfDialog').length === 1);
        await page.waitForFunction(() => Ext.ComponentQuery.query('pveAssignVfDialog')[0].isVisible());
        await page.waitForFunction(() => Ext.ComponentQuery.query('pveAssignVfDialog')[0].vmStore.findRecord('vmid', 202));
        assert.equal(await page.evaluate(() => Ext.ComponentQuery.query('pveAssignVfDialog')[0].vmStore.findRecord('vmid', 202).get('name')), 'Target');
        await page.screenshot({ path: process.env.GPU_SCREENSHOT || 'frontend-state.png' });
        await page.evaluate(() => Ext.ComponentQuery.query('pveAssignVfDialog')[0].close());

        // A failed fresh read must not open a dialog using cached permission.
        await page.evaluate(() => {
            api.fail = true;
            panel.openVfAssignmentDialog(panel.down('#vfGrid').getStore().first());
        });
        assert.equal(await page.evaluate(() => Ext.ComponentQuery.query('pveAssignVfDialog').length), 0);
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), true);
        assert.match(await page.evaluate(() => Ext.Msg.el.dom.textContent), /Failed to load SR-IOV status: Read failed/);
        assert.equal(await page.evaluate(() => panel.assignmentLoading), false);
        await page.evaluate(() => { Ext.Msg.hide(); api.fail = false; });

        // A topology change while the status request is in flight invalidates the selected VF.
        await page.evaluate(() => {
            api.hold = true;
            panel.openVfAssignmentDialog(panel.down('#vfGrid').getStore().first());
            vf.bdf = '0000:0c:00.1';
            api.pending.shift()(); api.hold = false;
        });
        assert.equal(await page.evaluate(() => Ext.ComponentQuery.query('pveAssignVfDialog').length), 0);
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), true);
        assert.match(await page.evaluate(() => Ext.Msg.el.dom.textContent), /topology changed/);
        await page.evaluate(() => Ext.Msg.hide());

        // Background failures never interrupt the user, even across retry intervals.
        await page.evaluate(() => { api.fail = true; });
        for (let i = 0; i < 2; i++) {
            await page.clock.runFor(15001);
            await page.evaluate(() => panel.refreshLiveTelemetry());
            assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), false);
        }
        await page.evaluate(() => { api.fail = false; api.empty = true;
            panel.openVfAssignmentDialog(panel.down('#vfGrid').getStore().first()); });
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), true);
        assert.match(await page.evaluate(() => Ext.Msg.el.dom.textContent), /empty SR-IOV/);
        await page.evaluate(() => { Ext.Msg.hide(); api.empty = false; api.hold = true;
            panel.openVfAssignmentDialog(panel.down('#vfGrid').getStore().first()); });
        assert.equal(await page.evaluate(() => panel.assignmentLoading), true);
        await page.evaluate(() => { panel.reloadSriov(); api.pending.shift()(); });
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), true);
        assert.match(await page.evaluate(() => Ext.Msg.el.dom.textContent), /Please retry/);
        assert.equal(await page.evaluate(() => panel.assignmentLoading), false);
        await page.evaluate(() => { Ext.Msg.hide(); api.pending.shift()(); api.hold = false; });

        // Slow full-status reads must not be restarted by telemetry ticks.
        await page.clock.runFor(15001);
        await page.evaluate(() => { api.hold = true; panel.refreshLiveTelemetry(); });
        await page.clock.runFor(15001);
        await page.evaluate(() => panel.refreshLiveTelemetry());
        assert.equal(await page.evaluate(() => api.pending.length), 1);
        await page.evaluate(() => { api.pending.shift()(); api.hold = false; });

        // An older list response cannot overwrite a newer full-status snapshot.
        await page.evaluate(() => {
            api.holdVf = true; vf.vmid = 201; panel.reloadVfs();
            vf.vmid = 202; panel.reloadSriov(); api.vfReply(); api.holdVf = false;
        });
        assert.equal(await page.evaluate(() => panel.down('#vfGrid').getStore().first().get('vmid')), 202);

        // Ordinary refresh races are not user errors, on either transport outcome.
        for (const failed of [false, true]) {
            await page.evaluate(failed => {
                api.hold = true;
                panel.reloadSriov(); panel.reloadSriov();
                api.fail = failed; api.pending.shift()();
                api.fail = false; api.pending.shift()(); api.hold = false;
            }, failed);
            assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), false);
            await page.evaluate(failed => {
                api.hold = true; panel.reloadSriov();
                panel.loadDevice(Ext.create('Ext.data.Model', {
                    bdf: '0000:0d:00.0', driver: 'xe', sriov_maxvfs: 4,
                }));
                api.fail = failed; api.pending.shift()();
                api.fail = false; api.pending.shift()(); api.hold = false;
                panel.loadDevice(device);
            }, failed);
            assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), false);
        }

        // Older status responses without embedded VFs still update policy.
        await page.evaluate(() => { api.omitVfs = true; api.drift = true; panel.reloadSriov(); });
        assert.equal(await page.evaluate(() => panel.down('#driftBanner').isVisible()), true);
        assert.equal(await page.evaluate(() => panel.down('#vfGrid').getStore().first().get('vmid')), 202);
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), false);
        await page.evaluate(() => { api.omitVfs = false; api.drift = false; panel.reloadSriov(); });

        // Late completions must not call back into a destroyed component.
        await page.evaluate(() => {
            api.hold = true; window.destroyedCallback = false;
            panel.reloadSriov(() => { window.destroyedCallback = true; });
            panel.destroy(); api.pending.shift()(); api.hold = false;
        });
        assert.equal(await page.evaluate(() => window.destroyedCallback), false);
        assert.equal(await page.evaluate(() => Ext.Msg.isVisible()), false);
        assert.deepEqual(errors, []);
        console.log('PASS: real ExtJS save/close, drift reconciliation, fresh assignment, read failure, topology change, slow polling');
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
