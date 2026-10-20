import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {readSelection} from './boundedSelection.js';

const SERVICE = 'com.rsitech.ClipVault.Capture';
const PATH = '/com/rsitech/ClipVault/Capture';
const IFACE = 'com.rsitech.ClipVault.Capture';
const LIMIT = 10 * 1024 * 1024;
const MARKERS = ['application/x-clipvault-copy', 'x-kde-passwordManagerHint',
    'application/x-keepassxc', 'application/x-1password'];

function call(destination, path, iface, method, params, signature, cancellable) {
    return new Promise((resolve, reject) => {
        Gio.DBus.session.call(destination, path, iface, method, params,
            new GLib.VariantType(signature), Gio.DBusCallFlags.NONE, 2000,
            cancellable, (connection, result) => {
                try { resolve(connection.call_finish(result).deep_unpack()); }
                catch (error) { reject(error); }
            });
    });
}

export default class ClipVaultCapture extends Extension {
    enable() {
        this._active = true;
        this._cancel = new Gio.Cancellable();
        this._generation = 0;
        this._selection = global.display.get_selection();
        this._signal = this._selection.connect('owner-changed', (_selection, type) => {
            if (type === Meta.SelectionType.SELECTION_CLIPBOARD)
                this._capture(++this._generation).catch(() => {});
        });
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._destination().catch(() => {});
            return GLib.SOURCE_CONTINUE;
        });
        this._destination().catch(() => {});
    }

    async _destination() {
        if (!this._active) return null;
        const bus = 'org.freedesktop.DBus';
        const busPath = '/org/freedesktop/DBus';
        const [owner] = await call(bus, busPath, bus, 'GetNameOwner',
            new GLib.Variant('(s)', [SERVICE]), '(s)', this._cancel);
        const [pid] = await call(bus, busPath, bus, 'GetConnectionUnixProcessID',
            new GLib.Variant('(s)', [owner]), '(u)', this._cancel);
        if (GLib.file_read_link(`/proc/${pid}/exe`) !== '/usr/bin/clipvault-linux')
            return null;
        const info = Gio.File.new_for_path('/usr/bin/clipvault-linux')
            .query_info('unix::uid', Gio.FileQueryInfoFlags.NONE, this._cancel);
        if (info.get_attribute_uint32('unix::uid') !== 0) return null;
        const [capturing] = await call(owner, PATH, IFACE, 'Heartbeat', null, '(b)', this._cancel);
        return this._active && capturing ? owner : null;
    }

    async _capture(generation) {
        const destination = await this._destination();
        if (!destination || !this._active || generation !== this._generation) return;
        const type = Meta.SelectionType.SELECTION_CLIPBOARD;
        const types = this._selection.get_mimetypes(type) ?? [];
        if (MARKERS.some(marker => types.includes(marker))) return;
        const clip = {kind: 'text', text: '', display_text: '', captured_at:
            Math.floor(Date.now() / 1000), source_app: null, source_device: null,
        image_png: null, metadata: {}};
        if (types.includes('image/png')) {
            const bytes = await readSelection(this._selection, type, 'image/png', LIMIT, this._cancel);
            if (!bytes || bytes.get_size() > LIMIT) return;
            clip.kind = 'image'; clip.display_text = 'Image';
            clip.image_png = GLib.base64_encode(bytes.get_data());
        } else {
            const mime = ['text/plain;charset=utf-8', 'UTF8_STRING', 'text/plain']
                .find(value => types.includes(value));
            if (!mime) return;
            const bytes = await readSelection(this._selection, type, mime, LIMIT, this._cancel);
            if (!bytes) return;
            const text = new TextDecoder('utf-8', {fatal: true}).decode(bytes.get_data());
            if (!text) return;
            clip.text = text; clip.display_text = text;
        }
        if (!this._active || generation !== this._generation) return;
        if (clip.kind === 'text') {
            const mime = types.includes('application/rtf') ? 'application/rtf' : types.includes('text/rtf') ? 'text/rtf' : null;
            if (mime) {
                const rtf = await readSelection(this._selection, type, mime, LIMIT, this._cancel);
                if (rtf && rtf.get_size() <= LIMIT) {
                    clip.kind = 'richText'; clip.metadata.rtf = GLib.base64_encode(rtf.get_data());
                }
            }
        }
        if (!this._active || generation !== this._generation) return;
        // Address the verified unique owner, never the replaceable well-known name.
        await call(destination, PATH, IFACE, 'Capture',
            new GLib.Variant('(s)', [JSON.stringify(clip)]), '(b)', this._cancel);
    }

    disable() {
        this._active = false;
        this._cancel?.cancel();
        if (this._signal) this._selection.disconnect(this._signal);
        if (this._timer) GLib.source_remove(this._timer);
        this._signal = 0; this._timer = 0; this._selection = null;
    }
}
