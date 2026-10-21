import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {readSelection} from '../rust/DeviceSync/linux/gnome-extension/boundedSelection.js';

function expect(value, message) { if (!value) throw new Error(message); }

async function transfer(length, limit) {
    const source = {
        transfer_async(type, mime, size, output, cancellable, callback) {
            expect(size === limit + 1, 'the native transfer must have a byte cap');
            expect(type === 1 && mime === 'text/plain', 'selection arguments changed');
            output.write_all(new Uint8Array(Math.min(size, length)).fill(65), cancellable);
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                callback(this, null);
                return GLib.SOURCE_REMOVE;
            });
        },
        transfer_finish() { return true; },
    };
    return readSelection(source, 1, 'text/plain', limit, new Gio.Cancellable());
}

expect((await transfer(64, 64)).get_size() === 64, 'exact limit must be accepted');
expect(await transfer(65, 64) === null, 'oversize clipboard must be rejected');
expect((await transfer(0, 64)).get_size() === 0, 'empty clipboard transfer must complete');
const cancelled = new Gio.Cancellable();
cancelled.cancel();
let read = false;
try {
    await readSelection({transfer_async() { read = true; }}, 1, 'text/plain', 64, cancelled);
} catch { /* expected cancellation */ }
expect(!read, 'cancelled capture must not begin a clipboard read');
print('PASS: bounded GNOME transfer arguments, exact limit, oversize, empty and cancellation');
