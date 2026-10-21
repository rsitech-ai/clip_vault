import Gio from 'gi://Gio';

// Meta.Selection.transfer_async enforces the limit while reading the source.
// Reading with St.Clipboard first and checking its GBytes size afterwards can
// allocate an arbitrarily large clipboard inside GNOME Shell.
export function readSelection(selection, type, mime, limit, cancellable) {
    if (cancellable?.is_cancelled())
        return Promise.reject(new Error('Capture cancelled'));
    const output = Gio.MemoryOutputStream.new_resizable();
    return new Promise((resolve, reject) => {
        selection.transfer_async(type, mime, limit + 1, output, cancellable,
            (source, result) => {
                try {
                    if (!source.transfer_finish(result))
                        throw new Error('Clipboard transfer failed');
                    output.close(null);
                    resolve(output.get_data_size() <= limit ? output.steal_as_bytes() : null);
                } catch (error) {
                    try { output.close(null); } catch { /* already closed */ }
                    reject(error);
                }
            });
    });
}
