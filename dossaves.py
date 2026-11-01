#!/usr/bin/env python3
"""dossaves.py - make DOSBox Pure's in-game saves reach RomM. Used by install.sh.

  dossaves.py ejs <emulatorjs data dir>    (the folder holding loader.js)
  dossaves.py src <frontend dir>           (RomM's app/frontend, before the build)

--- ejs ---
EmulatorJS 4.2.3 extracts a zipped game into its in-memory filesystem and
DOSBox Pure mounts that folder as C:, so whatever the game writes stays in memory
and is gone when the tab closes. DOSBox Pure also has no libretro SaveRAM, so
the ".srm" file RomM syncs through gameManager.getSaveFile() never exists.

(Handing DOSBox Pure the zip itself, so it keeps its own <game>.pure.zip, is not
an option: this core build crashes with "memory access out of bounds" while
starting many real game zips that way.)

This patch adds a small helper (EJS_RommDos, prepended to the bundle) and hooks:
- startGame: for dosbox_pure, records the files in the game folder at boot and
  restores this browser's last save copy, if any.
- getSaveFile: first packs every file the game created or changed since boot
  into /data/saves/DOSBox-pure/<rom name>.pure.zip (a plain stored zip; the
  same files always give the same bytes). That path is also returned by
- getSaveFilePath, so RomM uploads/downloads it like any save, and
- loadSaveFiles: unpacks that zip into the game folder (RomM then restarts the
  core, which sees the files).
/data/saves is EmulatorJS' IndexedDB-backed folder, so the copy also survives
in the browser. The helper also reads deflate-compressed zips.

Applied to the minified bundle (normal use) and to the source files (loaded when
RomM's EJS_DEBUG is on).

--- src ---
RomM's "Save & Quit" button takes a save state first and stops there if the
core refuses (DOSBox Pure does whenever no game program runs, e.g. after
quitting to DOS or its start menu): nothing is saved and the player doesn't
quit. The patch makes a refused state non-fatal: the save file is still
uploaded and the player quits.

Both modes are idempotent and exit non-zero if an anchor is missing (upstream
changed the code), naming the file.
"""
import pathlib
import sys

MARK = "/*romm-dos-saves*/"

HELPER = r"""/*romm-dos-saves*/(function () {
    "use strict";
    // In-game saves for EmulatorJS's DOSBox Pure core, for RomM (dossaves.py).
    // DOSBox Pure mounts the folder EmulatorJS extracted the game into, so the game
    // writes straight into the in-memory filesystem. This collects every file the
    // game created or changed since boot into one zip (the "save file" RomM syncs),
    // and unpacks such a zip back into the game folder to load a save.
    if (typeof window === "undefined" || window.EJS_RommDos) return;

    const SAVE_DIR = "/data/saves/DOSBox-pure";
    // Top-level names EmulatorJS/RetroArch use when the game folder is "/" itself
    const ROOT_SKIP = /^(dev|proc|tmp|home|data|shader|PPSSPP|game\.state|\d+-quick\.state)$/;

    const CRC_TABLE = (() => {
        const t = new Uint32Array(256);
        for (let n = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
            t[n] = c >>> 0;
        }
        return t;
    })();
    function crc32(b) {
        let c = 0xFFFFFFFF;
        for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]) & 255] ^ (c >>> 8);
        return (c ^ 0xFFFFFFFF) >>> 0;
    }
    function toDos(ms) {
        const d = new Date(ms), y = Math.min(2107, Math.max(1980, d.getFullYear()));
        return {
            time: (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1),
            date: ((y - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(),
        };
    }
    function fromDos(time, date) {
        return new Date(1980 + (date >> 9), ((date >> 5) & 15) - 1, date & 31,
            time >> 11, (time >> 5) & 63, (time & 31) * 2).getTime();
    }

    // Stored (uncompressed) zip. Same files -> same bytes, so RomM only uploads real changes.
    function makeZip(entries) {
        const enc = new TextEncoder(), parts = [], central = [];
        let offset = 0;
        for (const e of entries) {
            const name = enc.encode(e.name), dt = toDos(e.mtime), crc = crc32(e.data);
            const lh = new DataView(new ArrayBuffer(30));
            lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 10, true);
            lh.setUint16(6, 0x0800, true); // UTF-8 names
            lh.setUint16(10, dt.time, true); lh.setUint16(12, dt.date, true);
            lh.setUint32(14, crc, true); lh.setUint32(18, e.data.length, true); lh.setUint32(22, e.data.length, true);
            lh.setUint16(26, name.length, true);
            const ch = new DataView(new ArrayBuffer(46));
            ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 10, true);
            ch.setUint16(8, 0x0800, true);
            ch.setUint16(12, dt.time, true); ch.setUint16(14, dt.date, true);
            ch.setUint32(16, crc, true); ch.setUint32(20, e.data.length, true); ch.setUint32(24, e.data.length, true);
            ch.setUint16(28, name.length, true); ch.setUint32(42, offset, true);
            parts.push(new Uint8Array(lh.buffer), name, e.data);
            central.push(new Uint8Array(ch.buffer), name);
            offset += 30 + name.length + e.data.length;
        }
        const cdSize = central.reduce((n, p) => n + p.length, 0);
        const end = new DataView(new ArrayBuffer(22));
        end.setUint32(0, 0x06054b50, true);
        end.setUint16(8, entries.length, true); end.setUint16(10, entries.length, true);
        end.setUint32(12, cdSize, true); end.setUint32(16, offset, true);
        const all = parts.concat(central, [new Uint8Array(end.buffer)]);
        const out = new Uint8Array(offset + cdSize + 22);
        let p = 0;
        for (const a of all) { out.set(a, p); p += a.length; }
        return out;
    }

    // Raw DEFLATE decoder (after zlib's puff.c), so zips from elsewhere load too.
    const LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
    const LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
    const DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
    const DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
    function huffman(lengths) {
        const counts = new Uint16Array(16), offs = new Uint16Array(16), symbols = new Uint16Array(lengths.length);
        for (let i = 0; i < lengths.length; i++) counts[lengths[i]]++;
        counts[0] = 0;
        for (let i = 1; i < 16; i++) offs[i] = offs[i - 1] + counts[i - 1];
        for (let i = 0; i < lengths.length; i++) if (lengths[i]) symbols[offs[lengths[i]]++] = i;
        return { counts, symbols };
    }
    function inflateRaw(src, size) {
        const out = new Uint8Array(size);
        let ip = 0, op = 0, bitbuf = 0, bitcnt = 0;
        const bits = (n) => {
            while (bitcnt < n) {
                if (ip >= src.length) throw new Error("truncated deflate data");
                bitbuf |= src[ip++] << bitcnt; bitcnt += 8;
            }
            const v = bitbuf & ((1 << n) - 1);
            bitbuf >>>= n; bitcnt -= n;
            return v;
        };
        const decode = (h) => {
            let code = 0, first = 0, index = 0;
            for (let len = 1; len < 16; len++) {
                code |= bits(1);
                const count = h.counts[len];
                if (code - count < first) return h.symbols[index + (code - first)];
                index += count; first += count; first <<= 1; code <<= 1;
            }
            throw new Error("bad deflate code");
        };
        const block = (lc, dc) => {
            for (;;) {
                let sym = decode(lc);
                if (sym < 256) { if (op >= size) throw new Error("deflate overrun"); out[op++] = sym; }
                else if (sym === 256) return;
                else {
                    sym -= 257;
                    if (sym >= 29) throw new Error("bad length code");
                    const len = LBASE[sym] + bits(LEXT[sym]);
                    const ds = decode(dc);
                    if (ds >= 30) throw new Error("bad distance code");
                    const dist = DBASE[ds] + bits(DEXT[ds]);
                    if (dist > op || op + len > size) throw new Error("bad deflate distance");
                    for (let k = 0; k < len; k++, op++) out[op] = out[op - dist];
                }
            }
        };
        let fixed = null, last;
        do {
            last = bits(1);
            const type = bits(2);
            if (type === 0) {
                bitbuf = 0; bitcnt = 0;
                const len = src[ip] | (src[ip + 1] << 8);
                ip += 4;
                if (ip + len > src.length || op + len > size) throw new Error("bad stored block");
                out.set(src.subarray(ip, ip + len), op); ip += len; op += len;
            } else if (type === 1) {
                if (!fixed) {
                    const l = new Uint8Array(288);
                    l.fill(8, 0, 144); l.fill(9, 144, 256); l.fill(7, 256, 280); l.fill(8, 280, 288);
                    fixed = [huffman(l), huffman(new Uint8Array(30).fill(5))];
                }
                block(fixed[0], fixed[1]);
            } else if (type === 2) {
                const nlen = bits(5) + 257, ndist = bits(5) + 1, ncode = bits(4) + 4;
                const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
                const cl = new Uint8Array(19);
                for (let i = 0; i < ncode; i++) cl[order[i]] = bits(3);
                const clh = huffman(cl), ll = new Uint8Array(nlen + ndist);
                for (let i = 0; i < nlen + ndist;) {
                    const sym = decode(clh);
                    if (sym < 16) { ll[i++] = sym; continue; }
                    let val = 0, rep;
                    if (sym === 16) { if (!i) throw new Error("bad repeat"); val = ll[i - 1]; rep = 3 + bits(2); }
                    else if (sym === 17) rep = 3 + bits(3);
                    else rep = 11 + bits(7);
                    if (i + rep > nlen + ndist) throw new Error("bad repeat length");
                    while (rep--) ll[i++] = val;
                }
                block(huffman(ll.subarray(0, nlen)), huffman(ll.subarray(nlen)));
            } else throw new Error("bad deflate block type");
        } while (!last);
        if (op !== size) throw new Error("deflate size mismatch");
        return out;
    }

    function readZip(buf) {
        const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength), out = [];
        let eocd = -1;
        for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
            if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
        }
        if (eocd < 0) throw new Error("not a zip file");
        const count = dv.getUint16(eocd + 10, true);
        let p = dv.getUint32(eocd + 16, true);
        for (let n = 0; n < count; n++) {
            if (dv.getUint32(p, true) !== 0x02014b50) throw new Error("bad zip directory");
            const flags = dv.getUint16(p + 8, true), method = dv.getUint16(p + 10, true);
            const time = dv.getUint16(p + 12, true), date = dv.getUint16(p + 14, true);
            const csize = dv.getUint32(p + 20, true), usize = dv.getUint32(p + 24, true);
            const nlen = dv.getUint16(p + 28, true), xlen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
            const lho = dv.getUint32(p + 42, true);
            const nameBytes = buf.subarray(p + 46, p + 46 + nlen);
            const name = new TextDecoder(flags & 0x0800 ? "utf-8" : "latin1").decode(nameBytes);
            p += 46 + nlen + xlen + clen;
            if (name.endsWith("/")) continue;
            if (flags & 1) throw new Error("encrypted zip entry: " + name);
            const start = lho + 30 + dv.getUint16(lho + 26, true) + dv.getUint16(lho + 28, true);
            const raw = buf.subarray(start, start + csize);
            let data;
            if (method === 0) data = raw.slice();
            else if (method === 8) data = inflateRaw(raw, usize);
            else throw new Error("unsupported zip compression method " + method + " for " + name);
            if (crc32(data) !== dv.getUint32(p - 46 - nlen - xlen - clen + 16, true)) throw new Error("CRC mismatch for " + name);
            out.push({ name, data, mtime: fromDos(time, date) });
        }
        return out;
    }

    function walk(st) {
        const files = new Map(), FS = st.FS;
        const visit = (dir) => {
            let names;
            try { names = FS.readdir(dir); } catch (e) { return; }
            for (const n of names) {
                if (n === "." || n === "..") continue;
                if (dir === "/" && ROOT_SKIP.test(n)) continue;
                const p = (dir === "/" ? "" : dir) + "/" + n;
                let s;
                try { s = FS.stat(p); } catch (e) { continue; }
                if (FS.isDir(s.mode)) visit(p);
                else if (FS.isFile(s.mode)) files.set(p, { mtime: +s.mtime, size: s.size });
            }
        };
        visit(st.root);
        return files;
    }
    function mkdirs(FS, dir) {
        let cur = "";
        for (const part of dir.split("/")) {
            if (!part) continue;
            cur += "/" + part;
            if (!FS.analyzePath(cur).exists) FS.mkdir(cur);
        }
    }

    function refresh(st) {
        const now = walk(st), changed = [];
        for (const [p, s] of now) {
            const b = st.baseline.get(p);
            if (!b || b.mtime !== s.mtime || b.size !== s.size) changed.push([p, s.mtime, s.size]);
        }
        changed.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
        const key = JSON.stringify(changed);
        if (key === st.key) return;
        st.key = key;
        if (!changed.length) {
            if (st.FS.analyzePath(st.path).exists) st.FS.unlink(st.path);
            return;
        }
        const prefix = st.root === "/" ? "/" : st.root + "/";
        const zip = makeZip(changed.map(([p, mtime]) => ({ name: p.slice(prefix.length), data: st.FS.readFile(p), mtime })));
        st.FS.writeFile(st.path, zip);
    }

    function apply(st) {
        const FS = st.FS;
        if (!FS.analyzePath(st.path).exists) return;
        let entries;
        try { entries = readZip(FS.readFile(st.path)); } catch (e) { console.warn("[RomM DOS saves] can't read save:", e); return; }
        for (const e of entries) {
            const rel = e.name.replace(/\\/g, "/").split("/").filter((s) => s && s !== "." && s !== "..");
            if (!rel.length) continue;
            const target = (st.root === "/" ? "" : st.root) + "/" + rel.join("/");
            if (st.root === "/" && ROOT_SKIP.test(rel[0])) continue;
            mkdirs(FS, target.slice(0, target.lastIndexOf("/")));
            FS.writeFile(target, e.data);
            try { FS.utime(target, e.mtime, e.mtime); } catch (err) { /* keeps the write time */ }
        }
        st.key = null;
        console.log("[RomM DOS saves] loaded " + entries.length + " file(s) from " + st.path);
    }

    window.EJS_RommDos = {
        init(emu) {
            // The whole extracted tree: DOSBox Pure mounts the folder of the file it was
            // given (or a .conf decides), so "/" minus EmulatorJS' own folders covers all cases.
            const FS = emu.gameManager.FS, root = "/";
            let base = emu.getBaseFileName(true) || "game";
            try { base = decodeURIComponent(base); } catch (e) { /* keep as is */ }
            base = base.replace(/[\/\\]/g, "_").replace(/\.(zip|7z|rar|dosz|dosc)$/i, "") || "game";
            mkdirs(FS, SAVE_DIR);
            const st = { FS, root, path: SAVE_DIR + "/" + base + ".pure.zip", key: null, baseline: null };
            st.baseline = walk(st);
            emu.rommDos = { path: st.path, root, refresh: () => refresh(st), apply: () => apply(st) };
            apply(st); // this browser's last copy, if any; RomM may load the server's after start
            console.log("[RomM DOS saves] game folder " + root + ", save file " + st.path);
        },
        _test: { makeZip, readZip, inflateRaw, crc32 },
    };
})();"""

INIT_MIN = 'if("dosbox_pure"===this.getCore()&&window.EJS_RommDos)window.EJS_RommDos.init(this);'
INIT_SRC = '            if (this.getCore() === "dosbox_pure" && window.EJS_RommDos) window.EJS_RommDos.init(this);\n'

# (anchor, replacement); a replacement of None means "prepend HELPER to the file"
EJS_PATCHES = {
    "emulator.min.js": [
        (None, None),
        ("startGame(){try{", "startGame(){try{" + INIT_MIN),
    ],
    "src/emulator.js": [
        (None, None),
        ("    startGame() {\n        try {\n", "    startGame() {\n        try {\n" + INIT_SRC),
    ],
    "src/GameManager.js": [
        (
            "    getSaveFilePath() {\n        return this.functions.getSaveFilePath();\n    }\n",
            "    getSaveFilePath() {\n        " + MARK + "\n"
            "        return this.EJS.rommDos ? this.EJS.rommDos.path : this.functions.getSaveFilePath();\n    }\n",
        ),
        (
            "    getSaveFile(save) {\n        if (save !== false) {\n            this.saveSaveFiles();\n        }\n",
            "    getSaveFile(save) {\n        if (save !== false) {\n            this.saveSaveFiles();\n        }\n"
            "        if (this.EJS.rommDos) this.EJS.rommDos.refresh();\n",
        ),
        (
            "    loadSaveFiles() {\n        this.clearEJSResetTimer();\n",
            "    loadSaveFiles() {\n        if (this.EJS.rommDos) this.EJS.rommDos.apply();\n        this.clearEJSResetTimer();\n",
        ),
    ],
}
# The minified GameManager lives inside emulator.min.js
EJS_PATCHES["emulator.min.js"] += [
    (
        "getSaveFilePath(){return this.functions.getSaveFilePath()}",
        "getSaveFilePath(){return this.EJS.rommDos?this.EJS.rommDos.path:this.functions.getSaveFilePath()}",
    ),
    (
        "getSaveFile(t){!1!==t&&this.saveSaveFiles();return",
        "getSaveFile(t){!1!==t&&this.saveSaveFiles();this.EJS.rommDos&&this.EJS.rommDos.refresh();return",
    ),
    (
        "loadSaveFiles(){this.clearEJSResetTimer(),this.functions.loadSaveFiles()}",
        "loadSaveFiles(){this.EJS.rommDos&&this.EJS.rommDos.apply(),this.clearEJSResetTimer(),this.functions.loadSaveFiles()}",
    ),
]

SRC_PATCHES = {
    "src/views/Player/EmulatorJS/Player.vue": [
        (
            "    const stateFile = window.EJS_emulator.gameManager.getState();\n",
            "    " + MARK + "\n"
            "    // DOSBox Pure refuses a state while no game program runs (quit to DOS or\n"
            "    // its start menu): save the save file anyway and still quit.\n"
            "    let stateFile: ArrayBuffer | null = null;\n"
            "    try {\n"
            "      stateFile = window.EJS_emulator.gameManager.getState();\n"
            "    } catch (error) {\n"
            "      console.warn(\"Save state failed, saving the save file only\", error);\n"
            "    }\n",
            "replace",
        ),
        (
            "      saveState({ rom: romRef.value, stateFile, screenshotFile }),\n      saveFile?.byteLength\n",
            "      stateFile\n"
            "        ? saveState({ rom: romRef.value, stateFile, screenshotFile })\n"
            "        : undefined,\n"
            "      saveFile?.byteLength\n",
            "replace",
        ),
    ],
}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("ejs", "src"):
        print("usage: dossaves.py {ejs <emulatorjs data dir> | src <frontend dir>}", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[2])
    for rel, patches in (EJS_PATCHES if sys.argv[1] == "ejs" else SRC_PATCHES).items():
        path = root / rel
        text = path.read_text(encoding="utf-8")
        if MARK in text:
            print(f"dossaves: {rel} already patched")
            continue
        for patch in patches:
            anchor, code = patch[0], patch[1]
            if anchor is None:
                text = HELPER + "\n" + text
                continue
            if text.count(anchor) != 1:
                print(f"dossaves: anchor not found exactly once in {rel}: {anchor[:70]!r}...", file=sys.stderr)
                return 1
            text = text.replace(anchor, code)
        path.write_text(text, encoding="utf-8")
        print(f"dossaves: patched {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
