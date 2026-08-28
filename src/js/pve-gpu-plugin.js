/*
 * GPU Manager for Proxmox VE
 * ExtJS 7 frontend for supported Intel Battlemage SR-IOV management
 *
 * Registers a "GPU" tab in PVE.node.Config with:
 *   - Device grid (auto-refresh 30s)
 *   - Device detail panel (properties, telemetry, SR-IOV management)
 *   - VF lifecycle management (create, remove)
 *   - Drift warning banner
 */

/* =========================================================================
 * Utility helpers
 * ========================================================================= */

/**
 * Convert bytes to a human-readable string (B, KB, MB, GB, TB).
 * @param {number} bytes
 * @returns {string}
 */
function gpuFormatBytes(bytes) {
    if (bytes === null || bytes === undefined || isNaN(bytes)) {
        return '-';
    }
    if (bytes === 0) {
        return '0 B';
    }
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var exp = Math.floor(Math.log(bytes) / Math.log(1024));
    exp = Math.min(exp, units.length - 1);
    var value = bytes / Math.pow(1024, exp);
    return value.toFixed(2) + ' ' + units[exp];
}

/**
 * Return a CSS colour token based on GPU temperature.
 * @param {number} temp  Temperature in °C
 * @returns {string}     CSS colour string
 */
function gpuTempColour(temp) {
    if (temp >= 86) {
        return '#e84040'; // red
    }
    if (temp >= 70) {
        return '#f0a020'; // orange
    }
    return '#26a826'; // green
}

/* =========================================================================
 * GpuDeviceStore — backs the main device grid
 * ========================================================================= */

Ext.define('PVE.store.GpuDevices', {
    extend: 'Ext.data.Store',
    alias: 'store.gpuDevices',

    fields: [
        'bdf',
        'device_name',
        'vendor_id',
        'device_id',
        { name: 'subsystem_vendor_id', mapping: 'subsystem_vendor' },
        { name: 'subsystem_device_id', mapping: 'subsystem_device' },
        'family',
        'drm_card',
        { name: 'drm_render', mapping: 'render_node' },
        'driver',
        { name: 'numa_node', type: 'int' },
        { name: 'tiles', type: 'int' },
        { name: 'sriov_capable', type: 'boolean' },
        { name: 'sriov_maxvfs', type: 'int' },
        { name: 'sriov_numvfs', type: 'int' },
        { name: 'persisted', type: 'boolean' },
        'telemetry',
        'firmware_version',
        { name: 'assigned_vms', type: 'auto' },
        { name: 'pf_assigned', type: 'boolean' },
        { name: 'pf_vmid', type: 'auto' },
        { name: 'vfio_configured', type: 'boolean' }
    ],

    proxy: {
        type: 'memory',
        reader: { type: 'json' }
    },

    sorters: [{ property: 'bdf', direction: 'ASC' }]
});

/* =========================================================================
 * GpuVfioDialog — choose the live PF driver and update its boot policy
 * ========================================================================= */

Ext.define('PVE.window.GpuVfioDialog', {
    extend: 'Ext.window.Window',
    alias: 'widget.gpuVfioDialog',

    title: gettext('Select GPU Driver'),
    width: 560,
    modal: true,
    resizable: false,
    bodyPadding: 12,
    layout: 'anchor',

    config: {
        pveSelNode: null,
        deviceRecord: null
    },

    initComponent: function() {
        var me = this;
        var rec = me.deviceRecord;
        var deviceName = rec ? (rec.get('device_name') || '-') : '-';
        var bdf = rec ? (rec.get('bdf') || '-') : '-';
        var currentDriver = rec ? (rec.get('driver') || '') : '';
        var targetDriver = currentDriver === 'vfio-pci' ? 'vfio-pci' : 'xe';

        me.currentDriver = currentDriver;
        me.driverStore = Ext.create('Ext.data.Store', {
            fields: ['value', 'label'],
            data: [
                { value: 'xe', label: gettext('xe (host driver)') },
                { value: 'vfio-pci', label: gettext('vfio-pci (VM passthrough)') }
            ]
        });

        me.items = [
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Device'),
                labelWidth: 130,
                value: Ext.htmlEncode(deviceName + ' (' + bdf + ')')
            },
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Current driver'),
                labelWidth: 130,
                value: Ext.htmlEncode(currentDriver || gettext('Unbound'))
            },
            {
                xtype: 'combobox',
                itemId: 'driverField',
                name: 'driver',
                fieldLabel: gettext('Target driver'),
                labelWidth: 130,
                anchor: '100%',
                store: me.driverStore,
                queryMode: 'local',
                editable: false,
                forceSelection: true,
                valueField: 'value',
                displayField: 'label',
                value: targetDriver,
                listeners: {
                    change: function() { me.updateState(); }
                }
            },
            {
                xtype: 'component',
                itemId: 'warning',
                margin: '10 0 0 135',
                padding: 7,
                hidden: true,
                style: 'background:#fff3cd;border:1px solid #e0ae38;color:#6b4b00;',
                html: ''
            }
        ];

        me.buttons = [
            {
                text: gettext('Cancel'),
                handler: function() { me.close(); }
            },
            {
                text: gettext('Apply'),
                itemId: 'applyBtn',
                iconCls: 'fa fa-check',
                handler: function() { me.submit(); }
            }
        ];

        me.callParent();
        me.updateState();
    },

    nodeName: function() {
        return this.pveSelNode && this.pveSelNode.data ?
            this.pveSelNode.data.node : undefined;
    },

    updateState: function() {
        var me = this;
        var field = me.down('#driverField');
        var target = field ? field.getValue() : null;
        var rec = me.deviceRecord;
        var activeVfs = rec ? Number(rec.get('sriov_numvfs') || 0) : 0;
        var pfAssigned = rec ? !!rec.get('pf_assigned') : false;
        var pfVmid = rec ? rec.get('pf_vmid') : null;
        var blocked = pfAssigned || (target === 'vfio-pci' && activeVfs > 0);
        var warning = me.down('#warning');

        if (warning) {
            if (blocked) {
                warning.setHtml('<i class="fa fa-ban"></i> ' +
                    Ext.htmlEncode(pfAssigned ?
                        Ext.String.format(
                            gettext('Detach this physical GPU from VM {0} before changing its driver.'),
                            pfVmid || '?'
                        ) :
                        gettext('Stop and remove all active VFs before binding the PF to vfio-pci.')));
                warning.setStyle('background', '#fde2e2');
                warning.setStyle('border-color', '#d66');
                warning.setStyle('color', '#7a1d1d');
                warning.show();
            } else {
                warning.hide();
            }
        }

        var apply = me.down('#applyBtn');
        if (apply) {
            apply.setDisabled(!target || blocked);
        }
    },

    submit: function() {
        var me = this;
        var field = me.down('#driverField');
        var target = field ? field.getValue() : null;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        var nodeName = me.nodeName();
        if (!nodeName || !bdf || (target !== 'xe' && target !== 'vfio-pci')) {
            return;
        }

        me.updateState();
        var apply = me.down('#applyBtn');
        if (!apply || apply.disabled) {
            return;
        }

        var action = target === 'vfio-pci' ? 'bind' : 'unbind';
        apply.setDisabled(true);
        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                '/hardware/gpu/' + encodeURIComponent(bdf) + '/vfio',
            method: 'POST',
            params: { action: action, persist: 1 },
            success: function(response) {
                var data = response.result && response.result.data;
                me.setLoading(false);
                me.close();
                me.fireEvent('vfiochanged', me, bdf, data);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                me.updateState();
                Ext.Msg.alert(gettext('Error'), error || response.htmlStatus);
            }
        });
    }
});

/* =========================================================================
 * GpuDeviceGrid — main device list
 * ========================================================================= */

Ext.define('PVE.grid.GpuDeviceGrid', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.gpuDeviceGrid',

    title: gettext('GPU Devices'),
    collapsible: false,
    stateful: false,

    config: {
        pveSelNode: null
    },

    store: {
        type: 'gpuDevices'
    },

    selModel: {
        mode: 'SINGLE',
        allowDeselect: false
    },

    columns: [
        {
            header: gettext('Device'),
            dataIndex: 'device_name',
            flex: 1,
            minWidth: 180
        },
        {
            header: gettext('BDF'),
            dataIndex: 'bdf',
            width: 130,
            renderer: function(val) {
                return '<span class="x-monospace">' + Ext.htmlEncode(val) + '</span>';
            }
        },
        {
            header: gettext('GPU Core'),
            dataIndex: 'telemetry',
            width: 80,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.temperature_c === null || telemetry.temperature_c === undefined) {
                    return '-';
                }
                var t = telemetry.temperature_c;
                var colour = gpuTempColour(t);
                return '<span style="color:' + colour + ';font-weight:bold;">' + t + '\u00b0C</span>';
            }
        },
        {
            header: gettext('GPU Mem'),
            dataIndex: 'telemetry',
            width: 80,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.mem_temperature_c === null || telemetry.mem_temperature_c === undefined) {
                    return '-';
                }
                var t = telemetry.mem_temperature_c;
                var colour = gpuTempColour(t);
                return '<span style="color:' + colour + ';font-weight:bold;">' + t + '\u00b0C</span>';
            }
        },
        {
            header: gettext('Power'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry) { return '-'; }
                if (telemetry.power_w !== null && telemetry.power_w !== undefined) {
                    return telemetry.power_w + 'W';
                }
                if (telemetry.power_tdp_w) {
                    return '<span style="color:#888;">' + telemetry.power_tdp_w + 'W</span>';
                }
                return '-';
            }
        },
        {
            header: gettext('Freq'),
            dataIndex: 'telemetry',
            width: 90,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || !telemetry.clock_mhz) { return '-'; }
                var text = telemetry.clock_mhz + ' MHz';
                if (telemetry.clock_max_mhz && telemetry.clock_max_mhz !== telemetry.clock_mhz) {
                    text += ' / ' + telemetry.clock_max_mhz;
                }
                return text;
            }
        },
        {
            header: gettext('VRAM'),
            dataIndex: 'telemetry',
            width: 140,
            renderer: function(telemetry) {
                if (!telemetry || telemetry.lmem_total_mb === null || telemetry.lmem_total_mb === undefined) {
                    return '-';
                }
                var total = telemetry.lmem_total_mb;
                var used = telemetry.lmem_used_mb || 0;
                var totalGiB = (total / 1024).toFixed(1);
                var usedGiB = (used / 1024).toFixed(1);
                var pct = total > 0 ? Math.round((used / total) * 100) : 0;
                var colour = pct > 80 ? '#e84040' : (pct > 50 ? '#f0a020' : '#26a826');
                return '<span style="color:' + colour + ';">' + usedGiB + '/' + totalGiB + ' GiB</span>';
            }
        },
        {
            header: gettext('GPU %'),
            dataIndex: 'telemetry',
            width: 65,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.gpu_util_pct === null || telemetry.gpu_util_pct === undefined) { return '-'; }
                var pct = parseFloat(telemetry.gpu_util_pct);
                var colour = pct > 80 ? '#e84040' : (pct > 50 ? '#f0a020' : '#26a826');
                return '<span style="color:' + colour + ';font-weight:bold;">' + pct + '%</span>';
            }
        },
        {
            header: gettext('Fan'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.fan_rpm === null || telemetry.fan_rpm === undefined) { return '-'; }
                return telemetry.fan_rpm + ' rpm';
            }
        },
        {
            header: gettext('Health'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || !telemetry.health) { return '-'; }
                if (telemetry.health === 'OK') {
                    return '<span style="color:#26a826;"><i class="fa fa-check-circle"></i> OK</span>';
                }
                return '<span style="color:#e84040;"><i class="fa fa-exclamation-triangle"></i></span>';
            }
        },
        {
            header: gettext('Max VFs'),
            dataIndex: 'sriov_maxvfs',
            width: 60,
            align: 'center'
        },
        {
            header: gettext('VMs'),
            dataIndex: 'assigned_vms',
            width: 100,
            renderer: function(vms) {
                if (!vms || !vms.length) { return '\u2014'; }
                return vms.join(', ');
            }
        },
        {
            header: gettext('SR-IOV'),
            dataIndex: 'bdf',
            width: 120,
            renderer: function(val, meta, record) {
                var capable = record.get('sriov_capable') || record.get('sriov_maxvfs') > 0;
                if (!capable) {
                    return '<span style="color:#888;">' + gettext('N/A') + '</span>';
                }
                var numVfs = record.get('sriov_numvfs');
                if (numVfs > 0) {
                    return '<span style="color:#26a826;">' +
                        Ext.String.format(gettext('{0} VFs'), numVfs) +
                        '</span>';
                }
                return '<span style="color:#f0a020;">' + gettext('Ready') + '</span>';
            }
        },
        {
            header: gettext('Persisted'),
            dataIndex: 'persisted',
            width: 70,
            align: 'center',
            renderer: function(val) {
                if (val) {
                    return '<i class="fa fa-save" title="' + gettext('Persistent config saved') + '"></i>';
                }
                return '';
            }
        },
        {
            header: gettext('VFIO'),
            dataIndex: 'vfio_configured',
            width: 155,
            align: 'center',
            renderer: function(val, meta, record) {
                meta.tdStyle = 'cursor:pointer;';
                meta.tdAttr = 'data-qtip="' + Ext.htmlEncode(
                    gettext('Click to choose the PF driver')
                ) + '"';
                var driver = record.get('driver') || gettext('Unbound');
                var liveColour = driver === 'vfio-pci' ? '#e84040' : '#2673b8';
                return '<span style="color:' + liveColour + ';font-weight:bold;text-decoration:underline;">' +
                    Ext.htmlEncode(gettext('Live') + ': ' + driver) + '</span><br>' +
                    '<span style="color:#777;font-size:90%;">' +
                    Ext.htmlEncode(gettext('Boot VFIO') + ': ' + (val ? gettext('Yes') : gettext('No'))) +
                    '</span>';
            }
        }
    ],

    tbar: [
        {
            xtype: 'button',
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('gpuDeviceGrid').reload();
            }
        }
    ],

    initComponent: function() {
        var me = this;

        me.callParent();

        me.reloadRequestId = 0;

        me.on('selectionchange', function(selModel, records) {
            if (records.length > 0) {
                var rec = records[0];
                me.fireEvent('deviceselect', me, rec);
            }
        });

        me.on('cellclick', function(view, td, cellIndex, record, tr, rowIndex, e) {
            var column = view.getHeaderCt().getHeaderAtIndex(cellIndex);
            if (column && column.dataIndex === 'vfio_configured') {
                me.fireEvent('vfioclick', me, record, e);
            }
        });

        me.on('itemdblclick', function(grid, record) {
            me.fireEvent('devicedblclick', me, record);
        });

        me.taskRunner = new Ext.util.TaskRunner();

        me.on('afterrender', function() {
            me.reload();
            me.refreshTask = me.taskRunner.start({
                run: function() { me.reload(); },
                interval: 30000
            });
        });

        me.on('destroy', function() {
            if (me.refreshTask) {
                me.taskRunner.stop(me.refreshTask);
            }
        });
    },

    reload: function(preferredBdf) {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName) {
            return;
        }

        var selected = me.getSelectionModel().getSelection();
        var selectedBdf = preferredBdf || (selected.length ? selected[0].get('bdf') : null);
        var requestId = ++me.reloadRequestId;

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) + '/hardware/gpu',
            method: 'GET',
            success: function(response) {
                if (requestId !== me.reloadRequestId) {
                    return;
                }
                var data = response.result && response.result.data;
                if (Ext.isArray(data)) {
                    var store = me.getStore();
                    var currentSelection = me.getSelectionModel().getSelection();
                    var currentBdf = currentSelection.length ? currentSelection[0].get('bdf') : null;
                    var desiredBdf = currentBdf || selectedBdf;
                    store.loadData(data);

                    // loadData replaces records, so explicitly restore the
                    // selected BDF.  On first entry (or when it disappeared),
                    // select the first GPU so the detail panel is populated.
                    var next = desiredBdf ? store.findRecord('bdf', desiredBdf) : null;
                    next = next || store.getAt(0);
                    if (next) {
                        Ext.defer(function() {
                            if (me.destroyed || me.isDestroyed || requestId !== me.reloadRequestId) {
                                return;
                            }
                            var latest = me.getSelectionModel().getSelection();
                            if (latest.length && latest[0].get('bdf') !== desiredBdf) {
                                return;
                            }
                            me.getSelectionModel().select(next);
                        }, 0);
                    } else {
                        me.getSelectionModel().deselectAll();
                        me.fireEvent('deviceselect', me, null);
                    }
                }
            },
            failure: function(response, opts, error) {
                if (requestId !== me.reloadRequestId) {
                    return;
                }
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to load GPU devices: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    },

    openVfioDialog: function(record) {
        var me = this;
        if (!record) {
            return;
        }

        var dlg = Ext.create('PVE.window.GpuVfioDialog', {
            pveSelNode: me.pveSelNode,
            deviceRecord: record
        });
        dlg.on('vfiochanged', function(window, bdf, data) {
            // Reload using the changed BDF so the live driver, persistence
            // flag, and detail cards all follow the same selected record.
            me.reload(bdf);
            if (data && data.reboot_required) {
                Ext.Msg.alert(
                    gettext('Reboot Required'),
                    gettext('The VFIO boot configuration was updated. A reboot is required for the persistent change to take effect.')
                );
            }
        });
        dlg.show();
    }
});

/* =========================================================================
 * GpuPropertiesCard — key-value device properties
 * ========================================================================= */

Ext.define('PVE.panel.GpuPropertiesCard', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuPropertiesCard',

    title: gettext('Properties'),
    bodyPadding: 8,
    scrollable: 'y',

    tpl: [
        '<table class="gpu-props-table">',
        '<tpl for=".">',
        '<tr>',
        '<td class="gpu-props-key">{label}</td>',
        '<td class="gpu-props-val">{value}</td>',
        '</tr>',
        '</tpl>',
        '</table>'
    ],

    initComponent: function() {
        var me = this;
        me.items = [{
            xtype: 'dataview',
            itemId: 'propsView',
            store: Ext.create('Ext.data.Store', {
                fields: ['label', 'value']
            }),
            tpl: me.tpl,
            itemSelector: 'tr'
        }];
        me.callParent();
    },

    loadRecord: function(record) {
        var me = this;
        if (!record) {
            me.down('#propsView').getStore().removeAll();
            return;
        }
        var data = record.getData();
        var rows = [
            { label: gettext('Family'), value: Ext.htmlEncode(data.family || '-') },
            { label: gettext('Device ID'), value: Ext.htmlEncode(data.device_id || '-') },
            { label: gettext('Vendor ID'), value: Ext.htmlEncode(data.vendor_id || '-') },
            { label: gettext('Driver'), value: Ext.htmlEncode(data.driver || '-') },
            { label: gettext('Firmware'), value: Ext.htmlEncode(data.firmware_version || '-') },
            { label: gettext('DRM Card'), value: Ext.htmlEncode(data.drm_card || '-') },
            { label: gettext('Render Node'), value: Ext.htmlEncode(data.drm_render || '-') },
            { label: gettext('NUMA Node'), value: data.numa_node !== undefined ? String(data.numa_node) : '-' },
            { label: gettext('Tiles'), value: data.tiles !== undefined ? String(data.tiles) : '-' },
            { label: gettext('SR-IOV Max VFs'), value: data.sriov_maxvfs !== undefined ? String(data.sriov_maxvfs) : '-' },
            { label: gettext('SR-IOV Active VFs'), value: data.sriov_numvfs !== undefined ? String(data.sriov_numvfs) : '-' }
        ];
        me.down('#propsView').getStore().loadData(rows);
    }
});

/* =========================================================================
 * GpuTelemetryCard — live telemetry with auto-refresh
 * ========================================================================= */

Ext.define('PVE.panel.GpuTelemetryCard', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuTelemetryCard',

    title: gettext('Telemetry'),
    layout: { type: 'hbox', align: 'stretch', pack: 'start' },
    bodyPadding: 8,

    config: {
        pveSelNode: null,
        currentBdf: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Temperature gauge column
            {
                xtype: 'container',
                itemId: 'tempCol',
                flex: 1,
                padding: '0 8 0 0',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Temperature'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'progressbar',
                        itemId: 'tempBar',
                        height: 24,
                        value: 0,
                        text: '-'
                    },
                    {
                        xtype: 'label',
                        itemId: 'tempRange',
                        text: '0 \u00b0C  \u2015  105 \u00b0C',
                        style: 'font-size:10px;color:#888;margin-top:2px;'
                    }
                ]
            },
            // Power column
            {
                xtype: 'container',
                itemId: 'powerCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Power'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'powerVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        text: 'Watts',
                        style: 'font-size:10px;color:#888;'
                    }
                ]
            },
            // Clock rate column
            {
                xtype: 'container',
                itemId: 'clockCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Clock'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'clockVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'clockMax',
                        text: '',
                        style: 'font-size:10px;color:#888;'
                    }
                ]
            },
            // Fan speed column
            {
                xtype: 'container',
                itemId: 'fanCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Fan'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'fanVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        text: 'RPM',
                        style: 'font-size:10px;color:#888;'
                    }
                ]
            },
            // Memory bar column
            {
                xtype: 'container',
                itemId: 'memCol',
                flex: 2,
                padding: '0 0 0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Local Memory (LMEM)'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'progressbar',
                        itemId: 'memBar',
                        height: 24,
                        value: 0,
                        text: '-'
                    },
                    {
                        xtype: 'label',
                        itemId: 'memRange',
                        text: '0  \u2015  0',
                        style: 'font-size:10px;color:#888;margin-top:2px;'
                    }
                ]
            }
        ];

        me.callParent();

        me.taskRunner = new Ext.util.TaskRunner();
        me.telemetryRequestId = 0;

        me.on('afterrender', function() {
            me.refreshTask = me.taskRunner.start({
                run: function() { me.reloadTelemetry(); },
                interval: 10000
            });
        });

        me.on('destroy', function() {
            if (me.refreshTask) {
                me.taskRunner.stop(me.refreshTask);
            }
        });
    },

    loadDevice: function(record) {
        var me = this;
        me.clearDisplay();
        if (!record) {
            me.currentBdf = null;
            me.telemetryRequestId++;
            return;
        }
        me.currentBdf = record.get('bdf');
        // Render telemetry from the device record immediately
        me.updateDisplay(record.get('telemetry'));
        // Then kick off auto-refresh loop
        me.reloadTelemetry();
    },

    reloadTelemetry: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName || !me.currentBdf) {
            return;
        }
        var bdf = me.currentBdf;
        var requestId = ++me.telemetryRequestId;

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/gpu/' + encodeURIComponent(bdf),
            method: 'GET',
            success: function(response) {
                if (requestId !== me.telemetryRequestId || me.currentBdf !== bdf) {
                    return;
                }
                var data = response.result && response.result.data;
                me.updateDisplay(data && data.telemetry);
            },
            failure: Ext.emptyFn  // silent fail on telemetry refresh
        });
    },

    updateDisplay: function(telemetry) {
        var me = this;
        me.clearDisplay();
        if (!telemetry) {
            return;
        }

        // Temperature bar (0–105 °C range)
        var tempC = telemetry.temperature_c;
        var tempBar = me.down('#tempBar');
        if (tempBar && tempC !== null && tempC !== undefined) {
            var tempPct = Math.min(tempC / 105, 1);
            var colour = gpuTempColour(tempC);
            tempBar.updateProgress(tempPct, tempC + ' \u00b0C');
            // Colour the bar according to temperature severity
            tempBar.getEl().down('.x-progress-bar').setStyle('background-color', colour);
        }

        // Power label
        var powerVal = me.down('#powerVal');
        if (powerVal) {
            var pw = telemetry.power_w;
            if (pw !== null && pw !== undefined) {
                powerVal.setText(String(pw));
            } else if (telemetry.power_tdp_w) {
                powerVal.setText(telemetry.power_tdp_w + ' (TDP)');
            } else {
                powerVal.setText('-');
            }
        }

        // Clock rate
        var clockVal = me.down('#clockVal');
        var clockMax = me.down('#clockMax');
        if (clockVal) {
            var mhz = telemetry.clock_mhz;
            clockVal.setText(mhz !== null && mhz !== undefined ? mhz + ' MHz' : '-');
        }
        if (clockMax) {
            var maxMhz = telemetry.clock_max_mhz;
            clockMax.setText(maxMhz ? 'Max: ' + maxMhz + ' MHz' : '');
        }

        // Fan speed
        var fanVal = me.down('#fanVal');
        if (fanVal) {
            var rpm = telemetry.fan_rpm;
            fanVal.setText(rpm !== null && rpm !== undefined ? String(rpm) : '-');
        }

        // Memory bar (uses lmem_total_mb and lmem_used_mb from backend)
        var memBar = me.down('#memBar');
        var memRange = me.down('#memRange');
        var totalMb = telemetry.lmem_total_mb;
        var usedMb = telemetry.lmem_used_mb;
        if (memBar && totalMb !== null && totalMb !== undefined && totalMb > 0) {
            var used = usedMb || 0;
            var memPct = Math.min(used / totalMb, 1);
            var totalGiB = (totalMb / 1024).toFixed(1);
            var usedGiB = (used / 1024).toFixed(1);
            var memText = usedGiB + ' GiB / ' + totalGiB + ' GiB (' + Math.round(memPct * 100) + '%)';
            memBar.updateProgress(memPct, memText);
            if (memRange) {
                memRange.setText('0  \u2015  ' + totalGiB + ' GiB');
            }
        }
    },

    clearDisplay: function() {
        var me = this;
        var tempBar = me.down('#tempBar');
        if (tempBar) { tempBar.updateProgress(0, '-'); }
        var powerVal = me.down('#powerVal');
        if (powerVal) { powerVal.setText('-'); }
        var clockVal = me.down('#clockVal');
        if (clockVal) { clockVal.setText('-'); }
        var clockMax = me.down('#clockMax');
        if (clockMax) { clockMax.setText(''); }
        var fanVal = me.down('#fanVal');
        if (fanVal) { fanVal.setText('-'); }
        var memBar = me.down('#memBar');
        if (memBar) { memBar.updateProgress(0, '-'); }
        var memRange = me.down('#memRange');
        if (memRange) { memRange.setText('0  \u2015  0'); }
    }
});

/* =========================================================================
 * GpuPrecheckBar — SR-IOV prerequisite indicator strip
 * ========================================================================= */

Ext.define('PVE.panel.GpuPrecheckBar', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuPrecheckBar',

    title: gettext('SR-IOV Prerequisites'),
    layout: { type: 'hbox', align: 'middle', pack: 'start' },
    bodyPadding: 8,

    initComponent: function() {
        var me = this;

        me.checkDefinitions = [
            { name: 'cpu_virtualization', itemId: 'checkCpu', label: gettext('CPU Virtualization') },
            { name: 'iommu', itemId: 'checkIommu', label: gettext('IOMMU') },
            { name: 'sriov_bios', itemId: 'checkBios', label: gettext('SR-IOV BIOS') },
            { name: 'gpu_driver', itemId: 'checkDriver', label: gettext('GPU Driver') }
        ];
        me.items = me.buildCheckItems(me.checkDefinitions);

        me.callParent();
    },

    buildCheckItems: function(checks) {
        return checks.map(function(check) {
            return {
                xtype: 'container',
                itemId: check.itemId,
                flex: 1,
                margin: '0 4',
                padding: 6,
                style: 'border:1px solid #ddd;border-radius:4px;background:#f5f5f5;',
                layout: { type: 'vbox', align: 'center' },
                items: [
                    {
                        xtype: 'component',
                        itemId: 'icon',
                        html: '<i class="fa fa-question-circle" style="font-size:20px;color:#aaa;"></i>'
                    },
                    {
                        xtype: 'label',
                        text: check.label,
                        style: 'font-size:11px;margin-top:4px;text-align:center;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'msg',
                        text: '',
                        style: 'font-size:10px;color:#888;text-align:center;margin-top:2px;'
                    }
                ]
            };
        });
    },

    /**
     * Load precheck results from the sriov API response.
     * @param {Object} prechecks  Backend { checks, all_pass } status object
     * @returns {boolean}  true if all prechecks passed
     */
    loadPrechecks: function(prechecks) {
        var me = this;
        var checks = prechecks && prechecks.checks;

        me.checkDefinitions.forEach(function(definition) {
            var container = me.down('#' + definition.itemId);
            if (!container) { return; }

            var icon = container.down('#icon');
            var msg = container.down('#msg');
            var check = checks && checks[definition.name];

            if (!check) {
                if (icon) {
                    icon.update('<i class="fa fa-question-circle" style="font-size:20px;color:#aaa;"></i>');
                }
                if (msg) { msg.setText(''); }
                container.setStyle({ background: '#f5f5f5', borderColor: '#ddd' });
                return;
            }

            if (check.pass) {
                if (icon) {
                    icon.update('<i class="fa fa-check-circle" style="font-size:20px;color:#26a826;"></i>');
                }
                if (msg) { msg.setText(gettext('Pass')); }
                container.setStyle({ background: '#efffef', borderColor: '#b0d8b0' });
            } else {
                if (icon) {
                    icon.update('<i class="fa fa-times-circle" style="font-size:20px;color:#e84040;"></i>');
                }
                if (msg) { msg.setText(check.detail || gettext('Failed')); }
                container.setStyle({ background: '#fff2f2', borderColor: '#d8b0b0' });
            }
        });

        return !!(prechecks && prechecks.all_pass);
    }
});

/* =========================================================================
 * GpuDriftBanner — shown when persisted config != runtime state
 * ========================================================================= */

Ext.define('PVE.panel.GpuDriftBanner', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuDriftBanner',

    hidden: true,
    bodyStyle: 'background:#fffbe6;border:1px solid #f0a020;padding:8px 12px;',
    layout: 'hbox',

    config: {
        pveSelNode: null,
        currentBdf: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            {
                xtype: 'component',
                html: '<i class="fa fa-exclamation-triangle" style="font-size:20px;color:#f0a020;margin-right:8px;"></i>',
                margin: '0 8 0 0'
            },
            {
                xtype: 'container',
                flex: 1,
                layout: 'vbox',
                items: [
                    {
                        xtype: 'label',
                        itemId: 'driftTitle',
                        text: gettext('Configuration Drift Detected'),
                        style: 'font-weight:bold;color:#7a5000;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'driftMsg',
                        text: '',
                        style: 'color:#7a5000;'
                    }
                ]
            },
            {
                xtype: 'button',
                text: gettext('Review profiles'),
                iconCls: 'fa fa-sliders',
                margin: '0 4',
                handler: function() { me.fireEvent('reviewprofiles', me); }
            },
            {
                xtype: 'button',
                text: gettext('Dismiss'),
                handler: function() { me.hide(); }
            }
        ];

        me.callParent();
    },

    showDrift: function(drift) {
        var me = this;
        if (!drift || !drift.detected) {
            me.hide();
            return;
        }
        var msgCmp = me.down('#driftMsg');
        if (msgCmp) {
            msgCmp.setText(drift.message || gettext('Persisted SR-IOV configuration does not match running state.'));
        }
        me.show();
    }
});

/* =========================================================================
 * GpuVfStore — backs the VF grid
 * ========================================================================= */

var gpuVfResourceSpecs = [
    {
        name: 'vram',
        label: gettext('VRAM'),
        unit: 'GiB',
        byteValue: true,
        defaultStep: 0.125,
        minValue: 0.125,
        decimalPrecision: 3
    },
    {
        name: 'ggtt',
        label: gettext('GGTT'),
        unit: 'GiB',
        byteValue: true,
        defaultStep: 0.125,
        minValue: 0.125,
        decimalPrecision: 3
    },
    {
        name: 'contexts',
        label: gettext('Contexts'),
        unit: gettext('per GT'),
        minValue: 1,
        defaultStep: 1,
        decimalPrecision: 0
    },
    {
        name: 'doorbells',
        label: gettext('Doorbells'),
        unit: gettext('per GT'),
        minValue: 1,
        defaultStep: 1,
        decimalPrecision: 0
    },
    {
        name: 'exec_quantum_ms',
        label: gettext('Execution quantum'),
        unit: 'ms',
        minValue: 0,
        defaultStep: 1,
        decimalPrecision: 0
    },
    {
        name: 'preempt_timeout_us',
        label: gettext('Preemption timeout'),
        unit: 'µs',
        minValue: 0,
        defaultStep: 100,
        decimalPrecision: 0
    }
];

function gpuVfSpec(name) {
    for (var i = 0; i < gpuVfResourceSpecs.length; i++) {
        if (gpuVfResourceSpecs[i].name === name) {
            return gpuVfResourceSpecs[i];
        }
    }
    return null;
}

function gpuVfDisplayValue(name, value) {
    if (value === null || value === undefined || value === '' || isNaN(Number(value))) {
        return gettext('Unavailable');
    }
    var spec = gpuVfSpec(name);
    var numeric = Number(value);
    if (spec && spec.byteValue) {
        return gpuFormatBytes(numeric);
    }
    return String(numeric) + (spec && spec.unit ? ' ' + spec.unit : '');
}

function gpuVfResourceRenderer(name) {
    return function(resources) {
        var resource = resources && resources[name];
        if (!resource) {
            return '<span style="color:#888;">' + gettext('Unavailable') + '</span>';
        }

        var mode = resource.mode || 'unknown';
        var modeText = mode === 'auto' ? gettext('Auto') :
            (mode === 'custom' ? gettext('Custom') : gettext('Unknown'));
        var modeColour = mode === 'auto' ? '#2673b8' :
            (mode === 'custom' ? '#7a4ea3' : '#888');
        var configured = resource.configured;
        var effective = resource.effective;
        var liveText = resource.mixed ? gettext('Mixed') : gpuVfDisplayValue(name, effective);
        var text = '<span style="color:' + modeColour + ';font-weight:bold;">' +
            Ext.htmlEncode(modeText) + '</span>';

        if (mode === 'custom' && configured !== null && configured !== undefined) {
            text += ' ' + Ext.htmlEncode(gpuVfDisplayValue(name, configured));
        }
        text += '<br><span style="color:#777;font-size:90%;">' + gettext('Live') + ': ' +
            Ext.htmlEncode(liveText) + '</span>';
        return text;
    };
}

Ext.define('PVE.store.GpuVfs', {
    extend: 'Ext.data.Store',
    alias: 'store.gpuVfs',

    fields: [
        { name: 'vf_index', type: 'auto' },
        'bdf',
        'driver',
        'hostpci',
        { name: 'resources', type: 'auto' },
        { name: 'assigned', type: 'auto' },
        { name: 'running', type: 'auto' },
        { name: 'vmid', type: 'auto' }
    ],

    proxy: {
        type: 'memory',
        reader: { type: 'json' }
    },

    sorters: [{ property: 'vf_index', direction: 'ASC' }]
});

/* =========================================================================
 * ModifyVfsDialog — SR-IOV v2 per-VF profile editor
 * ========================================================================= */

Ext.define('PVE.window.ModifyVfsDialog', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveModifyVfsDialog',

    title: gettext('Modify Virtual Functions'),
    width: 980,
    height: 720,
    modal: true,
    resizable: true,
    scrollable: 'y',
    layout: { type: 'vbox', align: 'stretch' },
    bodyPadding: 10,

    config: {
        pveSelNode: null,
        deviceRecord: null,
        sriovStatus: null
    },

    initComponent: function() {
        var me = this;
        var rec = me.deviceRecord;
        var status = me.sriovStatus || {};
        var caps = status.capabilities || {};
        var deviceName = rec ? rec.get('device_name') : '-';
        var bdf = rec ? rec.get('bdf') : '-';
        var currentNumVfs = Number(status.sriov_numvfs !== undefined ?
            status.sriov_numvfs : (rec ? rec.get('sriov_numvfs') : 0)) || 0;
        var totalVfs = Number(caps.effective_max_vfs || status.sriov_maxvfs ||
            (rec ? rec.get('sriov_maxvfs') : 0)) || 0;
        var schedulerCaps = caps.scheduler || {};
        var persisted = status.persisted_config || {};
        var persistEnabled = status.persisted_config !== undefined ?
            Number(persisted.persist || 0) === 1 : !!(rec && rec.get('persisted'));
        var currentScheduler = status.scheduler_priority || status.sched_priority ||
            persisted.sched_priority || schedulerCaps.default || 'low';

        me.capabilities = caps;
        me.resourceCapabilities = caps.resources || {};
        me.schedulerCapabilities = schedulerCaps;
        me.currentNumVfs = currentNumVfs;
        me.currentScheduler = currentScheduler;
        me.totalVfs = totalVfs;
        me.apiReady = Number(status.api_version) >= 2 && !!caps.per_vf_profiles;
        me.vfRows = [];
        me.rowCache = {};
        me.hasAssignedConsumer = false;
        me.hasRunningConsumer = false;
        me.forceRequired = false;

        var schedulerStore = Ext.create('Ext.data.Store', {
            fields: ['value', 'text'],
            data: [
                { value: 'low', text: gettext('Low (recommended)') },
                { value: 'normal', text: gettext('Normal (experimental)') }
            ]
        });

        if (currentScheduler !== 'low' && currentScheduler !== 'normal') {
            currentScheduler = schedulerCaps.default === 'normal' ? 'normal' : 'low';
        }

        me.items = [
            {
                xtype: 'component',
                itemId: 'apiWarning',
                hidden: me.apiReady,
                margin: '0 0 10 0',
                padding: 8,
                style: 'background:#fde2e2;border:1px solid #d66;color:#7a1d1d;',
                html: '<i class="fa fa-ban"></i> ' +
                    Ext.htmlEncode(gettext('This editor requires the SR-IOV v2 API and per-VF profile capability.'))
            },
            {
                xtype: 'container',
                layout: { type: 'hbox', align: 'middle' },
                defaults: { xtype: 'displayfield', labelWidth: 85, margin: '0 20 0 0' },
                items: [
                    {
                        fieldLabel: gettext('Device'),
                        flex: 1,
                        value: Ext.htmlEncode(deviceName + ' (' + bdf + ')')
                    },
                    {
                        fieldLabel: gettext('Max VFs'),
                        width: 150,
                        value: String(totalVfs)
                    }
                ]
            },
            {
                xtype: 'numberfield',
                itemId: 'numVfsField',
                fieldLabel: gettext('Number of VFs'),
                labelWidth: 160,
                width: 330,
                name: 'num_vfs',
                value: currentNumVfs,
                minValue: 0,
                maxValue: totalVfs,
                allowDecimals: false,
                allowBlank: false,
                listeners: {
                    change: function(field, newVal) {
                        me.onVfCountChange(newVal);
                    }
                }
            },
            {
                xtype: 'component',
                itemId: 'consumerSummary',
                margin: '3 0 8 160',
                html: ''
            },
            {
                xtype: 'combo',
                itemId: 'schedulerField',
                fieldLabel: gettext('Scheduler priority'),
                labelWidth: 160,
                width: 430,
                store: schedulerStore,
                queryMode: 'local',
                displayField: 'text',
                valueField: 'value',
                editable: false,
                forceSelection: true,
                value: currentScheduler,
                disabled: schedulerCaps.supported === false || schedulerCaps.writable === false,
                listeners: {
                    change: function(field, value) {
                        var warning = me.down('#schedulerWarning');
                        if (warning) {
                            warning.setVisible(value === 'normal');
                        }
                        me.updateOperationState();
                    }
                }
            },
            {
                xtype: 'component',
                itemId: 'schedulerWarning',
                hidden: currentScheduler !== 'normal',
                margin: '0 0 8 160',
                padding: 7,
                style: 'background:#fff3cd;border:1px solid #e0ae38;color:#6b4b00;',
                html: '<i class="fa fa-exclamation-triangle"></i> ' +
                    Ext.htmlEncode(gettext('Normal is experimental on Intel B50. It may cause Windows Code 43, GuC errors, or loss of guest connectivity.'))
            },
            {
                xtype: 'checkbox',
                itemId: 'forceReprovisionCb',
                fieldLabel: gettext('Force VF reprovision'),
                labelWidth: 160,
                boxLabel: gettext('Destroy and recreate all VF PCI functions'),
                checked: false,
                listeners: {
                    change: function() { me.updateOperationState(); }
                }
            },
            {
                xtype: 'component',
                itemId: 'operationWarning',
                hidden: true,
                margin: '0 0 10 0',
                padding: 8,
                style: 'background:#fff3cd;border:1px solid #e0ae38;color:#6b4b00;',
                html: ''
            },
            {
                xtype: 'fieldset',
                title: gettext('Per-VF resource profiles'),
                itemId: 'vfProfilesFieldset',
                layout: { type: 'vbox', align: 'stretch' },
                defaults: { anchor: '100%' },
                items: []
            },
            {
                xtype: 'checkbox',
                itemId: 'persistCb',
                fieldLabel: gettext('Persist across reboots'),
                labelWidth: 160,
                checked: persistEnabled,
                inputValue: 1,
                uncheckedValue: 0
            },
            {
                xtype: 'component',
                margin: '0 0 0 160',
                style: 'color:#777;',
                html: Ext.htmlEncode(gettext('VF drivers will not be auto-probed; passthrough bindings remain under Proxmox control.'))
            }
        ];

        me.buttons = [
            {
                text: gettext('Cancel'),
                handler: function() { me.close(); }
            },
            {
                xtype: 'button',
                text: gettext('Apply'),
                itemId: 'applyBtn',
                iconCls: 'fa fa-check',
                disabled: true,
                handler: function() { me.doApply(); }
            }
        ];

        me.callParent();
    },

    resourceCapability: function(name) {
        return this.resourceCapabilities[name] || {
            supported: false,
            writable: false
        };
    },

    quotaToInput: function(name, quota) {
        if (quota === null || quota === undefined || quota === '' || isNaN(Number(quota))) {
            return null;
        }
        var spec = gpuVfSpec(name);
        return spec && spec.byteValue ? Number(quota) / (1024 * 1024 * 1024) : Number(quota);
    },

    inputToQuota: function(name, input) {
        if (input === null || input === undefined || input === '' || isNaN(Number(input))) {
            return null;
        }
        var spec = gpuVfSpec(name);
        return spec && spec.byteValue ? Math.round(Number(input) * 1024 * 1024 * 1024) : Math.round(Number(input));
    },

    newResourceState: function(name) {
        var cap = this.resourceCapability(name);
        return {
            name: name,
            mode: 'auto',
            initialMode: 'absent',
            quota: null,
            initialQuota: null,
            effective: null,
            mixed: false,
            supported: cap.supported !== false,
            writable: cap.writable !== false,
            capability: cap
        };
    },

    existingResourceState: function(name, source) {
        var me = this;
        var cap = me.resourceCapability(name);
        source = source || {};
        var sourceMode = source.mode || 'unknown';
        var effective = source.effective;
        var configured = source.configured;
        var mode;
        var quota;

        if (sourceMode === 'auto') {
            mode = 'auto';
            quota = null;
        } else if (sourceMode === 'custom') {
            mode = 'custom';
            quota = configured !== null && configured !== undefined ? configured : effective;
        } else {
            // v2 runtime state without provenance is made explicit.  Never
            // silently treat a live quota as driver-managed Auto.
            mode = 'custom';
            quota = effective;
        }

        return {
            name: name,
            mode: mode,
            initialMode: sourceMode,
            quota: quota !== null && quota !== undefined ? Number(quota) : null,
            initialQuota: quota !== null && quota !== undefined ? Number(quota) : null,
            effective: effective !== null && effective !== undefined ? Number(effective) : null,
            mixed: !!source.mixed,
            supported: cap.supported !== false,
            writable: cap.writable !== false && source.writable !== false,
            capability: cap
        };
    },

    newVfRow: function(index) {
        var me = this;
        var resources = {};
        gpuVfResourceSpecs.forEach(function(spec) {
            resources[spec.name] = me.newResourceState(spec.name);
        });
        return {
            vfIndex: index,
            bdf: '',
            assigned: false,
            running: false,
            vmid: null,
            hostpci: null,
            resources: resources
        };
    },

    loadVfData: function(vfStore) {
        var me = this;
        var assignments = (me.sriovStatus && me.sriovStatus.assignments) || [];
        var assignmentsByVf = {};
        assignments.forEach(function(assignment) {
            if (Number(assignment.vf_index) > 0) {
                assignmentsByVf[Number(assignment.vf_index)] = assignment;
            }
        });
        me.vfRows = [];
        me.rowCache = {};
        me.hasAssignedConsumer = assignments.length > 0;
        me.hasRunningConsumer = assignments.some(function(assignment) {
            return !!assignment.running;
        });

        for (var i = 1; i <= me.currentNumVfs; i++) {
            var vfRec = vfStore ? vfStore.findRecord('vf_index', i) : null;
            var resources = vfRec ? vfRec.get('resources') : null;
            var assignment = assignmentsByVf[i];
            var row = {
                vfIndex: i,
                bdf: vfRec ? (vfRec.get('bdf') || '') : '',
                assigned: assignment ? true : (vfRec ? !!vfRec.get('assigned') : false),
                running: assignment ? !!assignment.running : (vfRec ? !!vfRec.get('running') : false),
                vmid: assignment ? assignment.vmid : (vfRec ? vfRec.get('vmid') : null),
                hostpci: assignment ? assignment.key : (vfRec ? vfRec.get('hostpci') : null),
                resources: {}
            };

            gpuVfResourceSpecs.forEach(function(spec) {
                row.resources[spec.name] = me.existingResourceState(
                    spec.name,
                    resources && resources[spec.name]
                );
            });

            me.hasAssignedConsumer = me.hasAssignedConsumer || row.assigned;
            me.hasRunningConsumer = me.hasRunningConsumer || row.running;
            me.vfRows.push(row);
            me.rowCache[i] = row;
        }

        // Keep the v2 server's explicit blockers authoritative even if a
        // consumer disappears from an individual VF record during a refresh.
        var blocked = (me.sriovStatus && me.sriovStatus.change_blocked) || {};
        me.hasAssignedConsumer = me.hasAssignedConsumer || !!blocked.topology;
        me.hasRunningConsumer = me.hasRunningConsumer || !!blocked.resources;

        var persistField = me.down('#persistCb');
        if (persistField) {
            if (me.hasAssignedConsumer) {
                persistField.setValue(true);
            }
            persistField.setDisabled(me.hasAssignedConsumer);
        }

        me.updateConsumerSummary();
        me.rebuildVfRows();
        me.updateOperationState();
    },

    updateConsumerSummary: function() {
        var me = this;
        var parts = [];
        for (var i = 1; i <= me.currentNumVfs; i++) {
            var row = me.rowCache[i];
            if (!row || !row.assigned) { continue; }
            var text = gettext('VF') + row.vfIndex + ' → VM ' + (row.vmid || '?');
            text += row.running ? ' (' + gettext('running') + ')' : ' (' + gettext('stopped') + ')';
            parts.push(Ext.htmlEncode(text));
        }
        var summary = me.down('#consumerSummary');
        if (summary) {
            summary.setHtml(parts.length ?
                '<span style="color:' + (me.hasRunningConsumer ? '#b52b27' : '#666') + ';">' +
                parts.join(', ') + '</span>' :
                '<span style="color:#777;">' + Ext.htmlEncode(gettext('No VM consumers')) + '</span>');
        }
    },

    onVfCountChange: function(newCount) {
        var me = this;
        newCount = parseInt(newCount, 10);
        if (isNaN(newCount)) {
            me.updateOperationState();
            return;
        }
        newCount = Math.max(0, Math.min(newCount, me.totalVfs));

        if (newCount !== Number(me.down('#numVfsField').getValue())) {
            me.down('#numVfsField').setValue(newCount);
            return;
        }

        var rows = [];
        for (var i = 1; i <= newCount; i++) {
            var row = me.rowCache[i];
            if (!row) {
                row = me.newVfRow(i);
                me.rowCache[i] = row;
            }
            rows.push(row);
        }
        me.vfRows = rows;
        me.rebuildVfRows();
        me.updateOperationState();
    },

    resourceInputConfig: function(row, resource, spec) {
        var me = this;
        var cap = resource.capability || {};
        var alignment = Number(cap.alignment_bytes || 0);
        var step = spec.byteValue && alignment > 0 ?
            alignment / (1024 * 1024 * 1024) : spec.defaultStep;
        var inputValue = me.quotaToInput(spec.name, resource.quota);
        var custom = resource.mode === 'custom';
        var editable = resource.supported && resource.writable;

        var modeStore = Ext.create('Ext.data.Store', {
            fields: ['value', 'text'],
            data: [
                { value: 'auto', text: gettext('Auto') },
                { value: 'custom', text: gettext('Custom') }
            ]
        });

        var valueField;
        var modeField = Ext.create('Ext.form.field.ComboBox', {
            width: 110,
            margin: '0 8 0 0',
            store: modeStore,
            queryMode: 'local',
            displayField: 'text',
            valueField: 'value',
            editable: false,
            forceSelection: true,
            value: resource.mode,
            disabled: !editable,
            listeners: {
                change: function(field, value) {
                    resource.mode = value;
                    if (value === 'custom' && (resource.quota === null || resource.quota === undefined)) {
                        resource.quota = resource.effective !== null && resource.effective !== undefined ?
                            resource.effective : me.inputToQuota(spec.name, spec.minValue);
                    }
                    if (valueField) {
                        valueField.setValue(me.quotaToInput(spec.name, resource.quota));
                        valueField.setDisabled(value !== 'custom' || !editable);
                    }
                    me.updateOperationState();
                }
            }
        });

        valueField = Ext.create('Ext.form.field.Number', {
            width: 145,
            margin: '0 8 0 0',
            value: inputValue,
            minValue: spec.minValue,
            maxValue: 9007199254740991,
            step: step,
            decimalPrecision: spec.decimalPrecision,
            allowDecimals: spec.decimalPrecision > 0,
            allowBlank: !custom,
            disabled: !custom || !editable,
            emptyText: gettext('Driver managed'),
            listeners: {
                change: function(field, value) {
                    if (resource.mode === 'custom') {
                        resource.quota = me.inputToQuota(spec.name, value);
                    }
                    me.updateOperationState();
                }
            }
        });

        var liveText = resource.mixed ? gettext('Mixed values across GTs') :
            gpuVfDisplayValue(spec.name, resource.effective);
        if (!resource.supported) {
            liveText = gettext('Unsupported by this device/driver');
        } else if (!resource.writable) {
            liveText += ' (' + gettext('read-only') + ')';
        }

        return {
            xtype: 'container',
            layout: { type: 'hbox', align: 'middle' },
            margin: '2 0',
            items: [
                {
                    xtype: 'label',
                    text: spec.label,
                    width: 170
                },
                modeField,
                valueField,
                {
                    xtype: 'label',
                    text: spec.unit,
                    width: 70
                },
                {
                    xtype: 'component',
                    flex: 1,
                    html: '<span style="color:#777;">' + gettext('Live') + ': ' +
                        Ext.htmlEncode(liveText) + '</span>'
                }
            ]
        };
    },

    rebuildVfRows: function() {
        var me = this;
        var fieldset = me.down('#vfProfilesFieldset');
        if (!fieldset) { return; }
        fieldset.removeAll(true);

        fieldset.add({
            xtype: 'component',
            margin: '0 0 8 0',
            padding: 7,
            style: 'background:#eef6ff;border:1px solid #9fc2e8;color:#254d73;',
            html: '<strong>' + Ext.htmlEncode(gettext('Auto')) + ':</strong> ' +
                Ext.htmlEncode(gettext('the xe driver assigns the live value during VF provisioning; Auto never means a zero quota.')) +
                ' <strong>' + Ext.htmlEncode(gettext('Custom')) + ':</strong> ' +
                Ext.htmlEncode(gettext('write the exact value shown in this profile.')) + ' ' +
                Ext.htmlEncode(gettext('Existing values with unknown provenance are imported as Custom from their live effective value.'))
        });

        me.vfRows.forEach(function(row) {
            var title = gettext('VF') + ' ' + row.vfIndex;
            if (row.bdf) {
                title += ' — ' + row.bdf;
            }
            if (row.assigned) {
                title += ' — VM ' + (row.vmid || '?') +
                    (row.running ? ' (' + gettext('running') + ')' : ' (' + gettext('stopped') + ')');
            } else if (row.vfIndex > me.currentNumVfs) {
                title += ' — ' + gettext('new; driver-managed Auto defaults');
            }

            var resourceItems = [];
            gpuVfResourceSpecs.forEach(function(spec) {
                resourceItems.push(me.resourceInputConfig(row, row.resources[spec.name], spec));
            });

            fieldset.add({
                xtype: 'fieldset',
                title: Ext.htmlEncode(title),
                collapsible: true,
                collapsed: row.vfIndex > 1,
                margin: '3 0 8 0',
                layout: { type: 'vbox', align: 'stretch' },
                items: resourceItems
            });
        });

        if (me.vfRows.length === 0) {
            fieldset.add({
                xtype: 'component',
                padding: 8,
                style: 'color:#888;font-style:italic;',
                html: Ext.htmlEncode(gettext('No VFs will remain. Applying this operation removes every VF PCI function.'))
            });
        }
    },

    resourceValidationError: function() {
        var me = this;
        for (var i = 0; i < me.vfRows.length; i++) {
            var row = me.vfRows[i];
            for (var j = 0; j < gpuVfResourceSpecs.length; j++) {
                var spec = gpuVfResourceSpecs[j];
                var resource = row.resources[spec.name];
                if (resource.mode === 'auto') {
                    if (me.capabilities.auto_provisioning === false) {
                        return Ext.String.format(
                            gettext('VF{0} {1} cannot use Auto because driver auto-provisioning is unavailable.'),
                            row.vfIndex, spec.label);
                    }
                    continue;
                }
                if (!resource.supported || !resource.writable) {
                    return Ext.String.format(
                        gettext('VF{0} {1} is not writable on this device.'),
                        row.vfIndex, spec.label);
                }
                var quota = Number(resource.quota);
                var minimum = me.inputToQuota(spec.name, spec.minValue);
                if (!isFinite(quota) || Math.floor(quota) !== quota || quota < minimum) {
                    return Ext.String.format(
                        gettext('VF{0} has an invalid custom value for {1}.'),
                        row.vfIndex, spec.label);
                }
                var alignment = Number(resource.capability.alignment_bytes || 0);
                if (alignment > 0 && quota % alignment !== 0) {
                    return Ext.String.format(
                        gettext('VF{0} {1} must be aligned to {2}.'),
                        row.vfIndex, spec.label, gpuFormatBytes(alignment));
                }
            }
        }
        return null;
    },

    autoTransitionRequiresReprovision: function() {
        for (var i = 0; i < this.vfRows.length; i++) {
            var resources = this.vfRows[i].resources;
            for (var j = 0; j < gpuVfResourceSpecs.length; j++) {
                var resource = resources[gpuVfResourceSpecs[j].name];
                if (resource.mode === 'auto' &&
                    resource.initialMode !== 'auto' &&
                    resource.initialMode !== 'absent') {
                    return true;
                }
            }
        }
        return false;
    },

    updateOperationState: function() {
        var me = this;
        if (!me.rendered) { return; }
        var countField = me.down('#numVfsField');
        var targetCount = countField ? parseInt(countField.getValue(), 10) : me.currentNumVfs;
        targetCount = isNaN(targetCount) ? 0 : targetCount;
        var topologyChanged = targetCount !== me.currentNumVfs;
        var autoTransition = me.autoTransitionRequiresReprovision();
        var required = topologyChanged || autoTransition;
        var forceField = me.down('#forceReprovisionCb');

        if (forceField) {
            if (required) {
                if (!forceField.getValue()) {
                    forceField.suspendEvents(false);
                    forceField.setValue(true);
                    forceField.resumeEvents();
                }
                forceField.setDisabled(true);
            } else {
                if (me.forceRequired && forceField.getValue()) {
                    forceField.suspendEvents(false);
                    forceField.setValue(false);
                    forceField.resumeEvents();
                }
                forceField.setDisabled(false);
            }
        }
        me.forceRequired = required;
        var forceActive = forceField ? !!forceField.getValue() : required;
        var scheduler = me.down('#schedulerField');
        var schedulerValue = scheduler && !scheduler.disabled ? scheduler.getValue() : 'unchanged';
        var validationError = me.resourceValidationError();
        var blockers = [];
        var notices = [];

        if (!me.apiReady) {
            blockers.push(gettext('SR-IOV v2 per-VF profiles are unavailable.'));
        }
        if (me.hasRunningConsumer) {
            blockers.push(gettext('A consumer VM is running. Stop it before changing resources.'));
        }
        if (topologyChanged) {
            notices.push(gettext('Changing the VF count destroys and recreates every VF PCI function.'));
            if (me.hasAssignedConsumer) {
                blockers.push(gettext('Detach all assigned VFs before changing the VF count.'));
            }
        }
        if (autoTransition) {
            notices.push(gettext('Switching an existing resource to Auto requires a full VF reprovision.'));
        }
        if (forceActive && !topologyChanged && !autoTransition) {
            notices.push(gettext('Forced reprovision destroys and recreates every VF PCI function.'));
        }
        if (forceActive && me.hasAssignedConsumer) {
            blockers.push(gettext('Detach all assigned VFs before forcing reprovision.'));
        }
        if (schedulerValue === 'normal' && me.hasAssignedConsumer) {
            blockers.push(gettext('The experimental Normal scheduler cannot be enabled while a VF is assigned.'));
        }
        if (validationError) {
            blockers.push(validationError);
        }

        var warning = me.down('#operationWarning');
        if (warning) {
            var lines = notices.concat(blockers);
            warning.setVisible(lines.length > 0);
            warning.setHtml(lines.length ?
                '<i class="fa fa-exclamation-triangle"></i> ' +
                lines.map(function(line) { return Ext.htmlEncode(line); }).join('<br>') : '');
            warning.setStyle('background', blockers.length ? '#fde2e2' : '#fff3cd');
            warning.setStyle('border-color', blockers.length ? '#d66' : '#e0ae38');
            warning.setStyle('color', blockers.length ? '#7a1d1d' : '#6b4b00');
        }

        var apply = me.down('#applyBtn');
        if (apply) {
            apply.setDisabled(blockers.length > 0 || !countField || !countField.isValid());
            apply.setText(targetCount === 0 ? gettext('Remove all VFs') : gettext('Apply'));
            apply.setIconCls(targetCount === 0 ? 'fa fa-trash' : 'fa fa-check');
        }
    },

    buildProfiles: function() {
        return this.vfRows.map(function(row) {
            var resources = {};
            gpuVfResourceSpecs.forEach(function(spec) {
                var state = row.resources[spec.name];
                resources[spec.name] = { mode: state.mode };
                if (state.mode === 'custom') {
                    resources[spec.name].quota = Number(state.quota);
                }
            });
            return {
                vf_index: row.vfIndex,
                resources: resources
            };
        });
    },

    submitProfiles: function(params) {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/gpu/' + encodeURIComponent(bdf) + '/sriov',
            method: 'POST',
            params: params,
            success: function() {
                me.setLoading(false);
                me.close();
                me.fireEvent('vfsmodified', me);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to apply VF configuration: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    },

    doApply: function() {
        var me = this;
        me.updateOperationState();
        var apply = me.down('#applyBtn');
        if (!apply || apply.disabled) { return; }

        var targetCount = parseInt(me.down('#numVfsField').getValue(), 10) || 0;
        var schedulerField = me.down('#schedulerField');
        var scheduler = schedulerField && !schedulerField.disabled ?
            schedulerField.getValue() : 'unchanged';
        var forceReprovision = !!me.down('#forceReprovisionCb').getValue();
        var params = {
            num_vfs: targetCount,
            vf_profiles: Ext.encode(targetCount > 0 ? me.buildProfiles() : []),
            sched_priority: scheduler,
            allow_unsafe_scheduler: scheduler === 'normal' ? 1 : 0,
            force_reprovision: forceReprovision ? 1 : 0,
            persist: me.down('#persistCb').getValue() ? 1 : 0,
            drivers_autoprobe: 0
        };

        var submit = function() { me.submitProfiles(params); };
        var confirmScheduler = function() {
            if (scheduler !== 'normal' || targetCount === 0) {
                submit();
                return;
            }
            Ext.Msg.confirm(
                gettext('Enable experimental scheduler?'),
                gettext('Normal scheduling has caused Windows Code 43, GuC errors, and guest connectivity loss on Intel B50. Continue only with a tested rollback path.'),
                function(answer) {
                    if (answer === 'yes') { submit(); }
                }
            );
        };

        if (targetCount === 0) {
            Ext.Msg.confirm(
                gettext('Remove all VFs?'),
                gettext('All VF PCI functions will disappear and the persisted SR-IOV profile will be removed.'),
                function(answer) {
                    if (answer === 'yes') { confirmScheduler(); }
                }
            );
        } else {
            confirmScheduler();
        }
    }
});

/* =========================================================================
 * AssignVfDialog — stopped-VM VF assignment editor
 * ========================================================================= */

Ext.define('PVE.window.AssignVfDialog', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveAssignVfDialog',

    title: gettext('Assign Virtual Function'),
    width: 560,
    modal: true,
    resizable: false,
    bodyPadding: 12,
    layout: 'anchor',

    config: {
        pveSelNode: null,
        deviceRecord: null,
        vfRecord: null,
        assignmentPersistent: false
    },

    initComponent: function() {
        var me = this;
        var vf = me.vfRecord;
        var currentVmid = Number(vf.get('vmid')) || 0;
        var assignmentPersistent = me.getAssignmentPersistent();
        var initialRows = [{
            vmid: 0,
            name: '',
            status: 'none',
            label: '\u2014 ' + gettext('None (unassigned)')
        }];
        if (currentVmid && !assignmentPersistent) {
            initialRows.push({
                vmid: currentVmid,
                name: '',
                status: 'stopped',
                label: currentVmid + ' \u2014 ' + gettext('current VM')
            });
        }

        me.currentVmid = currentVmid;
        me.vmStore = Ext.create('Ext.data.Store', {
            fields: [
                { name: 'vmid', type: 'int' },
                'name',
                'status',
                'label'
            ],
            data: initialRows,
            sorters: [{ property: 'vmid', direction: 'ASC' }]
        });

        me.items = [
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Virtual Function'),
                labelWidth: 130,
                value: 'VF ' + Ext.htmlEncode(String(vf.get('vf_index'))) +
                    ' (' + Ext.htmlEncode(vf.get('bdf') || '-') + ')'
            },
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Current VM'),
                labelWidth: 130,
                value: currentVmid ? Ext.htmlEncode(String(currentVmid)) : gettext('None')
            },
            {
                xtype: 'combobox',
                itemId: 'vmField',
                fieldLabel: gettext('Assign to'),
                labelWidth: 130,
                anchor: '100%',
                store: me.vmStore,
                queryMode: 'local',
                editable: false,
                forceSelection: true,
                valueField: 'vmid',
                displayField: 'label',
                value: currentVmid,
                listConfig: {
                    getInnerTpl: function() {
                        return '{[Ext.htmlEncode(values.label)]}';
                    }
                },
                listeners: {
                    change: function(field, value) {
                        var apply = me.down('#applyAssignmentBtn');
                        if (apply) {
                            apply.setDisabled(Number(value) === me.currentVmid);
                        }
                    }
                }
            },
            {
                xtype: 'component',
                margin: '10 0 0 135',
                style: 'color:#666;',
                html: Ext.htmlEncode(gettext('Only stopped, unlocked QEMU VMs are listed. The VM must be stopped before assigning or removing a VF.'))
            },
            {
                xtype: 'component',
                hidden: assignmentPersistent,
                margin: '10 0 0 135',
                padding: 7,
                style: 'background:#fff3cd;border:1px solid #e0ae38;color:#6b4b00;',
                html: Ext.htmlEncode(gettext('This VF has no persistent SR-IOV profile. Only rescue unassignment to None is available.'))
            }
        ];

        me.buttons = [
            {
                text: gettext('Cancel'),
                handler: function() { me.close(); }
            },
            {
                text: gettext('Apply'),
                itemId: 'applyAssignmentBtn',
                iconCls: 'fa fa-check',
                disabled: true,
                handler: function() { me.confirmAndSubmit(); }
            }
        ];

        me.callParent();
        if (assignmentPersistent) {
            me.on('afterrender', function() { me.loadVms(); }, me, { single: true });
        }
    },

    nodeName: function() {
        return this.pveSelNode && this.pveSelNode.data ?
            this.pveSelNode.data.node : undefined;
    },

    loadVms: function() {
        var me = this;
        var nodeName = me.nodeName();
        if (!nodeName) { return; }
        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) + '/qemu',
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                var rows = [{
                    vmid: 0,
                    name: '',
                    status: 'none',
                    label: '\u2014 ' + gettext('None (unassigned)')
                }];
                Ext.Array.each(Ext.isArray(data) ? data : [], function(vm) {
                    var vmid = Number(vm.vmid) || 0;
                    if (!vmid || vm.template || vm.status !== 'stopped' || vm.lock) {
                        return;
                    }
                    var name = vm.name ? String(vm.name) : gettext('unnamed');
                    rows.push({
                        vmid: vmid,
                        name: name,
                        status: vm.status,
                        label: vmid + ' (' + name + ') \u2014 ' + gettext('stopped')
                    });
                });
                me.vmStore.loadData(rows);
                var field = me.down('#vmField');
                if (field) {
                    if (!me.vmStore.findRecord('vmid', me.currentVmid) && me.currentVmid) {
                        me.vmStore.add({
                            vmid: me.currentVmid,
                            name: '',
                            status: 'stopped',
                            label: me.currentVmid + ' \u2014 ' + gettext('current VM')
                        });
                    }
                    field.setValue(me.currentVmid);
                }
                me.setLoading(false);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to load QEMU VMs: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    },

    confirmAndSubmit: function() {
        var me = this;
        var targetVmid = Number(me.down('#vmField').getValue()) || 0;
        if (targetVmid === me.currentVmid) { return; }

        var vfLabel = 'VF ' + me.vfRecord.get('vf_index') +
            ' (' + (me.vfRecord.get('bdf') || '-') + ')';
        var message;
        if (!targetVmid) {
            message = Ext.String.format(
                gettext('Remove {0} from VM {1} and leave it unassigned?'),
                Ext.htmlEncode(vfLabel),
                Ext.htmlEncode(String(me.currentVmid))
            );
        } else if (me.currentVmid) {
            message = Ext.String.format(
                gettext('Move {0} from VM {1} to VM {2}?'),
                Ext.htmlEncode(vfLabel),
                Ext.htmlEncode(String(me.currentVmid)),
                Ext.htmlEncode(String(targetVmid))
            );
        } else {
            message = Ext.String.format(
                gettext('Assign {0} to VM {1}?'),
                Ext.htmlEncode(vfLabel),
                Ext.htmlEncode(String(targetVmid))
            );
        }

        Ext.Msg.confirm(gettext('Confirm VF assignment'), message, function(answer) {
            if (answer === 'yes') {
                me.submitAssignment(targetVmid);
            }
        });
    },

    submitAssignment: function(targetVmid) {
        var me = this;
        var nodeName = me.nodeName();
        var pfBdf = me.deviceRecord && me.deviceRecord.get('bdf');
        if (!nodeName || !pfBdf) { return; }

        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                '/hardware/gpu/' + encodeURIComponent(pfBdf) +
                '/vf/' + encodeURIComponent(me.vfRecord.get('vf_index')) +
                '/assignment',
            method: 'PUT',
            params: { vmid: targetVmid },
            success: function() {
                me.setLoading(false);
                me.fireEvent('assignmentchanged', me);
                me.close();
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), error || response.htmlStatus);
            }
        });
    }
});

/* =========================================================================
 * GpuSriovPanel — VF management section (precheck + VF grid)
 * ========================================================================= */

Ext.define('PVE.panel.GpuSriovPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuSriovPanel',

    title: gettext('SR-IOV Virtual Functions'),
    layout: { type: 'vbox', align: 'stretch' },

    config: {
        pveSelNode: null,
        deviceRecord: null
    },

    initComponent: function() {
        var me = this;

        me.sriovStatus = null;
        me.vfDataLoaded = false;
        me.sriovRequestId = 0;
        me.vfRequestId = 0;

        me.items = [
            // Drift banner
            {
                xtype: 'gpuDriftBanner',
                itemId: 'driftBanner',
                pveSelNode: me.pveSelNode,
                listeners: {
                    reviewprofiles: function() { me.openModifyDialog(); }
                }
            },
            {
                xtype: 'component',
                itemId: 'schedulerStatus',
                padding: '6 8',
                style: 'border-bottom:1px solid #ddd;color:#666;',
                html: Ext.htmlEncode(gettext('Scheduler: loading...'))
            },
            {
                xtype: 'gpuPrecheckBar',
                itemId: 'precheckBar'
            },
            // VF grid
            {
                xtype: 'gridpanel',
                itemId: 'vfGrid',
                flex: 1,
                store: { type: 'gpuVfs' },
                columns: [
                    { header: gettext('VF #'), dataIndex: 'vf_index', width: 60, align: 'center' },
                    {
                        header: gettext('BDF'), dataIndex: 'bdf', flex: 1, minWidth: 140,
                        renderer: function(val) {
                            return '<span class="x-monospace">' + Ext.htmlEncode(val || '-') + '</span>';
                        }
                    },
                    {
                        header: gettext('VRAM'), dataIndex: 'resources', width: 155,
                        renderer: gpuVfResourceRenderer('vram')
                    },
                    {
                        header: gettext('GGTT'), dataIndex: 'resources', width: 155,
                        renderer: gpuVfResourceRenderer('ggtt')
                    },
                    {
                        header: gettext('Contexts'), dataIndex: 'resources', width: 135,
                        renderer: gpuVfResourceRenderer('contexts')
                    },
                    {
                        header: gettext('Doorbells'), dataIndex: 'resources', width: 135,
                        renderer: gpuVfResourceRenderer('doorbells')
                    },
                    {
                        header: gettext('Exec quantum'), dataIndex: 'resources', width: 135,
                        renderer: gpuVfResourceRenderer('exec_quantum_ms')
                    },
                    {
                        header: gettext('Preempt timeout'), dataIndex: 'resources', width: 145,
                        renderer: gpuVfResourceRenderer('preempt_timeout_us')
                    },
                    {
                        header: gettext('Status'), dataIndex: 'assigned', width: 100,
                        renderer: function(val, meta, record) {
                            if (val) {
                                if (record.get('running')) {
                                    return '<span style="color:#b52b27;font-weight:bold;">' +
                                        gettext('VM running') + '</span>';
                                }
                                return '<span style="color:#b06b00;">' + gettext('Assigned') + '</span>';
                            }
                            return '<span style="color:#888;">' + gettext('Available') + '</span>';
                        }
                    },
                    {
                        header: gettext('VM'), dataIndex: 'vmid', width: 80,
                        renderer: function(val, meta) {
                            meta.tdStyle = 'cursor:pointer;';
                            meta.tdAttr = 'data-qtip="' + Ext.htmlEncode(
                                gettext('Double-click to assign this VF to a VM or leave it unassigned')
                            ) + '"';
                            return '<span style="color:#2673b8;text-decoration:underline;">' +
                                Ext.htmlEncode(val ? String(val) : gettext('None')) + '</span>';
                        }
                    }
                ],
                listeners: {
                    celldblclick: function(view, td, cellIndex, record) {
                        var column = view.getHeaderCt().getHeaderAtIndex(cellIndex);
                        if (column && column.dataIndex === 'vmid') {
                            me.openVfAssignmentDialog(record);
                        }
                    }
                },
                tbar: [
                    {
                        xtype: 'button',
                        itemId: 'modifyVfsBtn',
                        text: gettext('Modify VFs'),
                        iconCls: 'fa fa-sliders',
                        disabled: true,
                        handler: function() { me.openModifyDialog(); }
                    }
                ]
            }
        ];

        me.callParent();
    },

    /**
     * Load SR-IOV status for a device.
     * @param {Ext.data.Model} deviceRecord
     */
    loadDevice: function(deviceRecord) {
        var me = this;
        me.deviceRecord = deviceRecord;
        me.sriovStatus = null;
        me.vfDataLoaded = false;
        me.sriovRequestId++;
        me.vfRequestId++;

        var vfGrid = me.down('#vfGrid');
        vfGrid.getStore().removeAll();
        me.down('#modifyVfsBtn').setDisabled(true);
        me.down('#driftBanner').hide();
        me.down('#precheckBar').loadPrechecks(null);
        me.down('#precheckBar').show();
        me.down('#schedulerStatus').setHtml(
            Ext.htmlEncode(gettext('Scheduler: loading...'))
        );

        var maxVfs = deviceRecord ? (deviceRecord.get('sriov_maxvfs') || 0) : 0;
        var driver = deviceRecord ? (deviceRecord.get('driver') || '') : '';
        if (maxVfs <= 0 && driver !== 'vfio-pci') {
            me.setTitle(gettext('SR-IOV Virtual Functions'));
            me.hide();
            return;
        }
        me.show();

        // Disable SR-IOV management when PF is assigned to a VM (whole-GPU passthrough)
        var pfAssigned = deviceRecord.get('pf_assigned');
        var pfVmid = deviceRecord.get('pf_vmid');
        if (pfAssigned) {
            me.enable();
            me.setTitle(gettext('SR-IOV Virtual Functions') + ' \u2014 ' +
                Ext.String.format(gettext('GPU assigned to VM {0}'), pfVmid || '?'));
            me.down('#precheckBar').hide();
            me.down('#modifyVfsBtn').setDisabled(true);
            me.reloadVfs();
            return;
        }

        me.enable();
        me.setTitle(gettext('SR-IOV Virtual Functions'));
        me.reloadSriov();
        me.reloadVfs();
    },

    reloadSriov: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }
        var requestId = ++me.sriovRequestId;

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/gpu/' + encodeURIComponent(bdf) + '/sriov',
            method: 'GET',
            success: function(response) {
                if (requestId !== me.sriovRequestId || !me.isCurrentDevice(bdf)) {
                    return;
                }
                var data = response.result && response.result.data;
                if (!data) { return; }
                me.sriovStatus = data;
                me.down('#precheckBar').loadPrechecks(data.prechecks);

                // The v2 status response includes the same live VF records as
                // the list endpoint.  Load them immediately so the editor and
                // capability snapshot are from one coherent read.
                if (Ext.isArray(data.vfs)) {
                    var vfStore = me.down('#vfGrid').getStore();
                    vfStore.removeAll();
                    vfStore.loadData(data.vfs);
                    me.vfDataLoaded = true;
                }

                // Drift banner
                var driftBanner = me.down('#driftBanner');
                if (driftBanner) {
                    driftBanner.pveSelNode = me.pveSelNode;
                    driftBanner.currentBdf = bdf;
                    var drift = data.drift || {};
                    var driftMessage = drift.message;
                    if (!driftMessage && Ext.isArray(drift.issues) && drift.issues.length) {
                        driftMessage = drift.issues.join('; ');
                    }
                    driftBanner.showDrift({
                        detected: !!(drift.has_drift || data.config_drift),
                        message: driftMessage || gettext('Persisted SR-IOV configuration does not match the live VF count, scheduler, or resource profiles.')
                    });
                }

                var schedulerStatus = me.down('#schedulerStatus');
                if (schedulerStatus) {
                    var priority = data.scheduler_priority || gettext('Unavailable');
                    var colour = priority === 'low' ? '#2673b8' : '#b06b00';
                    var suffix;
                    if (priority === 'normal') {
                        suffix = ' — ' + gettext('experimental on Intel B50');
                    } else if (priority === 'low') {
                        suffix = ' — ' + gettext('recommended');
                    } else if (priority === 'mixed') {
                        suffix = ' — ' + gettext('inconsistent across VFs');
                    } else {
                        suffix = '';
                    }
                    schedulerStatus.setHtml(
                        '<strong>' + Ext.htmlEncode(gettext('Device scheduler')) + ':</strong> ' +
                        '<span style="color:' + colour + ';font-weight:bold;">' +
                        Ext.htmlEncode(String(priority)) + '</span>' + Ext.htmlEncode(suffix)
                    );
                }

                me.updateModifyButton();
            },
            failure: function(response, opts, error) {
                if (requestId !== me.sriovRequestId || !me.isCurrentDevice(bdf)) {
                    return;
                }
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to load SR-IOV status: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    },

    reloadVfs: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }
        var requestId = ++me.vfRequestId;

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/gpu/' + encodeURIComponent(bdf) + '/vf',
            method: 'GET',
            success: function(response) {
                if (requestId !== me.vfRequestId || !me.isCurrentDevice(bdf)) {
                    return;
                }
                var data = response.result && response.result.data;
                var store = me.down('#vfGrid').getStore();
                store.removeAll();
                if (Ext.isArray(data) && data.length > 0) {
                    store.loadData(data);
                }
                me.vfDataLoaded = true;
                me.updateModifyButton();
            },
            failure: function() {
                if (requestId !== me.vfRequestId || !me.isCurrentDevice(bdf)) {
                    return;
                }
                var store = me.down('#vfGrid').getStore();
                store.removeAll();
                me.vfDataLoaded = false;
                me.updateModifyButton();
            }
        });
    },

    isCurrentDevice: function(bdf) {
        return !!this.deviceRecord && this.deviceRecord.get('bdf') === bdf;
    },

    updateModifyButton: function() {
        var me = this;
        var button = me.down('#modifyVfsBtn');
        if (!button) { return; }
        var status = me.sriovStatus;
        var caps = status && status.capabilities;
        var apiReady = status && Number(status.api_version) >= 2 &&
            caps && !!caps.per_vf_profiles;
        var pfAssigned = me.deviceRecord && me.deviceRecord.get('pf_assigned');

        if (pfAssigned) {
            button.setDisabled(true);
            button.setTooltip(gettext('The physical GPU is assigned to a VM.'));
        } else if (!apiReady) {
            button.setDisabled(true);
            button.setTooltip(gettext('SR-IOV v2 per-VF profiles are required; no legacy fallback is available.'));
        } else if (!me.vfDataLoaded) {
            button.setDisabled(true);
            button.setTooltip(gettext('Waiting for live VF resource data.'));
        } else {
            button.setDisabled(false);
            var blocked = status.change_blocked || {};
            button.setTooltip(blocked.resources ?
                gettext('A consumer VM is running. You may inspect profiles, but Apply remains disabled until it is stopped.') : '');
        }
    },

    openModifyDialog: function() {
        var me = this;
        var caps = me.sriovStatus && me.sriovStatus.capabilities;
        if (!me.sriovStatus || Number(me.sriovStatus.api_version) < 2 ||
            !caps || !caps.per_vf_profiles) {
            Ext.Msg.alert(
                gettext('Unsupported API'),
                gettext('SR-IOV v2 per-VF profiles are required. This UI will not submit a legacy uniform-quota request.')
            );
            return;
        }
        var dlg = Ext.create('PVE.window.ModifyVfsDialog', {
            pveSelNode: me.pveSelNode,
            deviceRecord: me.deviceRecord,
            sriovStatus: me.sriovStatus
        });
        dlg.on('vfsmodified', function() {
            // Delay reload to let sysfs settle after VF count change
            Ext.defer(function() {
                me.reloadVfs();
                me.reloadSriov();
                me.fireEvent('vfschanged', me);
            }, 2000);
        });
        dlg.show();
        // Load current VF data from the grid store
        var vfStore = me.down('#vfGrid').getStore();
        dlg.loadVfData(vfStore);
    },

    openVfAssignmentDialog: function(vfRecord) {
        var me = this;
        var status = me.sriovStatus;
        var caps = status && status.capabilities;
        if (!status || Number(status.api_version) < 3 ||
            !caps || !caps.vf_vm_assignment) {
            Ext.Msg.alert(
                gettext('Unsupported API'),
                gettext('The installed backend does not support safe VF-to-VM assignment.')
            );
            return;
        }
        if (me.deviceRecord && me.deviceRecord.get('pf_assigned')) {
            Ext.Msg.alert(
                gettext('Unavailable'),
                gettext('The physical GPU is assigned to a VM.')
            );
            return;
        }
        if (vfRecord.get('running')) {
            Ext.Msg.alert(
                gettext('Stop VM first'),
                Ext.String.format(
                    gettext('Stop VM {0} before changing this VF assignment.'),
                    Ext.htmlEncode(String(vfRecord.get('vmid') || '?'))
                )
            );
            return;
        }

        var persisted = status.persisted_config || {};
        var assignmentPersistent = Number(persisted.persist || 0) === 1;
        var currentVmid = Number(vfRecord.get('vmid')) || 0;
        if (!assignmentPersistent && !currentVmid) {
            Ext.Msg.alert(
                gettext('Persistent profile required'),
                gettext('Enable Persist across reboots in Modify VFs before assigning this VF to a VM.')
            );
            return;
        }

        var dlg = Ext.create('PVE.window.AssignVfDialog', {
            pveSelNode: me.pveSelNode,
            deviceRecord: me.deviceRecord,
            vfRecord: vfRecord,
            assignmentPersistent: assignmentPersistent
        });
        dlg.on('assignmentchanged', function() {
            Ext.defer(function() {
                me.reloadVfs();
                me.reloadSriov();
                me.fireEvent('vfschanged', me);
            }, 500);
        });
        dlg.show();
    }
});

/* =========================================================================
 * GpuDeviceDetail — right/bottom panel shown on row selection
 * ========================================================================= */

Ext.define('PVE.panel.GpuDeviceDetail', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.gpuDeviceDetail',

    title: gettext('Device Detail'),
    layout: { type: 'vbox', align: 'stretch' },
    bodyPadding: 0,
    scrollable: 'y',

    config: {
        pveSelNode: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Top row: properties + telemetry side by side
            {
                xtype: 'container',
                layout: { type: 'hbox', align: 'stretch' },
                height: 230,
                items: [
                    {
                        xtype: 'gpuPropertiesCard',
                        itemId: 'propsCard',
                        flex: 1,
                        margin: '0 4 4 0',
                        border: true
                    },
                    {
                        xtype: 'gpuTelemetryCard',
                        itemId: 'telemetryCard',
                        flex: 2,
                        margin: '0 0 4 4',
                        border: true,
                        pveSelNode: me.pveSelNode
                    }
                ]
            },
            // SR-IOV panel
            {
                xtype: 'gpuSriovPanel',
                itemId: 'sriovPanel',
                flex: 1,
                minHeight: 280,
                pveSelNode: me.pveSelNode
            }
        ];

        me.callParent();

        // Propagate vfschanged up so the device grid can refresh
        me.down('#sriovPanel').on('vfschanged', function() {
            me.fireEvent('vfschanged', me);
        });
    },

    loadDevice: function(record) {
        var me = this;
        if (!record) {
            me.setTitle(gettext('Device Detail'));
            me.down('#propsCard').loadRecord(null);
            me.down('#telemetryCard').loadDevice(null);
            me.down('#sriovPanel').loadDevice(null);
            return;
        }

        me.setTitle(Ext.String.format(
            gettext('Device Detail: {0} ({1})'),
            record.get('device_name'),
            record.get('bdf')
        ));

        me.down('#propsCard').loadRecord(record);
        me.down('#telemetryCard').loadDevice(record);
        me.down('#sriovPanel').loadDevice(record);
    }
});

/* =========================================================================
 * GpuManager — the main node tab panel
 * ========================================================================= */

Ext.define('PVE.node.GpuManager', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveGpuManager',

    layout: { type: 'border' },

    config: {
        pveSelNode: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Device grid — north region
            {
                xtype: 'gpuDeviceGrid',
                itemId: 'deviceGrid',
                region: 'north',
                height: 240,
                split: true,
                pveSelNode: me.pveSelNode,
                listeners: {
                    deviceselect: function(grid, record) {
                        me.down('#deviceDetail').loadDevice(record);
                    },
                    vfioclick: function(grid, record) {
                        grid.openVfioDialog(record);
                    }
                }
            },
            // Device detail — center region
            {
                xtype: 'gpuDeviceDetail',
                itemId: 'deviceDetail',
                region: 'center',
                pveSelNode: me.pveSelNode,
                listeners: {
                    vfschanged: function() {
                        // Refresh device grid so VF counts / persisted icons update
                        me.down('#deviceGrid').reload();
                    }
                }
            }
        ];

        me.callParent();
    }
});

/* =========================================================================
 * Tab registration — inject GPU tab into PVE.node.Config
 *
 * PVE.node.Config uses an items array; we override initComponent on the
 * existing class to push our tab in. This follows the same pattern used by
 * other PVE UI plugins (e.g. PVE-mods).
 * ========================================================================= */

// Override PVE.node.Config to inject our GPU tab.
// PVE.panel.Config.initComponent processes me.items via insertNodes(),
// which adds them to both savedItems and the tree store for navigation.
// After callParent(), insertNodes() is still available to add more items.
Ext.define('PVE.node.GpuManagerOverride', {
    override: 'PVE.node.Config',

    initComponent: function() {
        var me = this;

        // Call the original initComponent chain
        me.callParent(arguments);

        // Use PVE.panel.Config's insertNodes to properly register our tab
        // in both the tree navigation and the card layout
        me.insertNodes([{
            xtype: 'pveGpuManager',
            title: gettext('GPU'),
            iconCls: 'fa fa-microchip',
            itemId: 'gpugpu',
            pveSelNode: me.pveSelNode,
            nodename: me.pveSelNode.data.node
        }]);
    }
});

/* =========================================================================
 * CSS injection — inline styles for monospace BDF and properties table
 * ========================================================================= */

(function() {
    var styleId = 'pve-gpu-plugin-styles';
    if (document.getElementById(styleId)) { return; }

    var style = document.createElement('style');
    style.id = styleId;
    style.type = 'text/css';
    // PVE Proxmox Dark theme loads a separate CSS file that sets
    // --pwt-panel-background and --pwt-text-color on :root, plus
    // color-scheme:dark. It does NOT add a body class.
    //
    // Strategy: use color-scheme media query for dark detection,
    // since PVE dark theme sets color-scheme:dark on :root which
    // propagates to prefers-color-scheme media queries.
    style.textContent = [
        '.x-monospace { font-family: monospace; }',

        // Light mode (default)
        '.gpu-props-table {',
        '  width: 100%;',
        '  border-collapse: collapse;',
        '  border: 1px solid #e0e0e0;',
        '}',
        '.gpu-props-table tr:nth-child(even) { background: #f0f0f0; }',
        '.gpu-props-table tr:nth-child(odd) { background: #fafafa; }',
        '.gpu-props-table tr:hover { background: #e0ecf5; }',
        '.gpu-props-key {',
        '  padding: 5px 10px;',
        '  font-weight: 600;',
        '  color: #444;',
        '  width: 150px;',
        '  white-space: nowrap;',
        '  border-right: 1px solid #e0e0e0;',
        '  opacity: 0.8;',
        '}',
        '.gpu-props-val {',
        '  padding: 5px 10px;',
        '  font-family: monospace;',
        '  color: #222;',
        '}'
    ].join('\n');

    // Dark mode: dynamically update styles when dark theme is detected.
    // PVE dark theme loads a CSS file that sets --pwt-panel-background on :root.
    // We detect this and inject dark overrides with !important to ensure they win.
    var darkStyleId = 'pve-gpu-plugin-dark';
    var darkCSS = [
        '.gpu-props-table { border-color: #404040 !important; }',
        '.gpu-props-table tr:nth-child(even) { background: #1a1a1a !important; }',
        '.gpu-props-table tr:nth-child(odd) { background: #262626 !important; }',
        '.gpu-props-table tr:hover { background: #595959 !important; }',
        '.gpu-props-key { color: #b0b0b0 !important; border-right-color: #404040 !important; }',
        '.gpu-props-val { color: #f2f2f2 !important; }'
    ].join('\n');

    var applyTheme = function() {
        var pwtBg = getComputedStyle(document.documentElement)
            .getPropertyValue('--pwt-panel-background').trim();
        var isDark = pwtBg !== '';
        var darkEl = document.getElementById(darkStyleId);

        if (isDark && !darkEl) {
            var ds = document.createElement('style');
            ds.id = darkStyleId;
            ds.textContent = darkCSS;
            document.head.appendChild(ds);
        } else if (!isDark && darkEl) {
            darkEl.remove();
        }
    };

    // Check theme on load, after short delays (CSS may not be parsed yet),
    // and on any stylesheet changes
    applyTheme();
    setTimeout(applyTheme, 500);
    setTimeout(applyTheme, 2000);
    new MutationObserver(function() {
        applyTheme();
        setTimeout(applyTheme, 200);
    }).observe(document.head, { childList: true });
    document.head.appendChild(style);
}());
