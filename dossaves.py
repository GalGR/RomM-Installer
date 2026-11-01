#!/usr/bin/env python3
"""dossaves.py - make DOSBox Pure's in-game saves reach RomM. Used by install.sh.

  dossaves.py ejs <emulatorjs data dir>    (the folder holding loader.js)
  dossaves.py src <frontend dir>           (RomM's app/frontend, before the build)

--- ejs ---

EmulatorJS 4.2.3 unpacks every zipped ROM into its in-memory filesystem and
starts the first file, so DOSBox Pure mounts that folder directly: whatever the
game writes lands in memory and is gone when the tab closes. And DOSBox Pure has
no libretro SaveRAM (its retro_get_memory_size returns 0), so the ".srm" path
RomM reads through gameManager.getSaveFile() never exists.

Two exact-string patches, applied to both the minified bundle (normal use) and
the source files (loaded instead when RomM's EJS_DEBUG is on):

1. downloadRom: for the dosbox_pure core, a ZIP is written as-is (named
   <base>.zip) and handed to the core. DOSBox Pure then mounts it read-only with
   a writable overlay and stores everything the game writes in
   <save dir>/<base>.pure.zip, which lives in EmulatorJS' persistent
   /data/saves (IndexedDB). 7z/RAR and non-archives keep the old behaviour.
2. getSaveFilePath: for that case it returns the .pure.zip path instead of the
   .srm one, so RomM's existing save sync (upload tick, Sync save, Quit, Save &
   Quit, loading a save from the server) reads and writes that file.

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

# JS shared by both patches. {data}/{resolve} are the variable names in scope.
HANDOFF = (
    MARK + 'if("dosbox_pure"===this.getCore()){{const romm_u8=new Uint8Array({data});'
    "if(romm_u8.length>3&&80===romm_u8[0]&&75===romm_u8[1]&&3===romm_u8[2]&&4===romm_u8[3]){{"
    "let romm_b=this.getBaseFileName(!0);try{{romm_b=decodeURIComponent(romm_b)}}catch(romm_x){{}}"
    'romm_b=romm_b.replace(/[\\/\\\\]/g,"_");'
    'if(!/\\.(zip|dosz|dosc)$/i.test(romm_b))romm_b+=".zip";'
    'this.fileName=romm_b;this.gameManager.FS.writeFile("/"+romm_b,romm_u8);{resolve}();return}}}}'
)
SAVE_PATH = (
    MARK + "const romm_p=this.functions.getSaveFilePath();"
    'return"dosbox_pure"===this.EJS.getCore()&&/\\.(zip|dosz|dosc)$/i.test(this.EJS.fileName||"")'
    '?romm_p.replace(/\\.srm$/,".pure.zip"):romm_p'
)

EJS_PATCHES = {
    "emulator.min.js": [
        (
            'if(["arcade","mame"].includes(this.getCore(!0)))return this.fileName=this.getBaseFileName(!0),'
            "this.gameManager.FS.writeFile(this.fileName,new Uint8Array(i)),void e();",
            HANDOFF.format(data="i", resolve="e"),
            "after",
        ),
        (
            "getSaveFilePath(){return this.functions.getSaveFilePath()}",
            "getSaveFilePath(){" + SAVE_PATH + "}",
            "replace",
        ),
    ],
    "src/emulator.js": [
        (
            '                if (["arcade", "mame"].includes(this.getCore(true))) {\n'
            "                    this.fileName = this.getBaseFileName(true);\n"
            "                    this.gameManager.FS.writeFile(this.fileName, new Uint8Array(data));\n"
            "                    resolve();\n"
            "                    return;\n"
            "                }\n",
            "                " + HANDOFF.format(data="data", resolve="resolve") + "\n",
            "after",
        ),
    ],
    "src/GameManager.js": [
        (
            "    getSaveFilePath() {\n        return this.functions.getSaveFilePath();\n    }\n",
            "    getSaveFilePath() {\n        " + SAVE_PATH + ";\n    }\n",
            "replace",
        ),
    ],
}


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
        for anchor, code, how in patches:
            if text.count(anchor) != 1:
                print(f"dossaves: anchor not found exactly once in {rel}: {anchor[:70]!r}...", file=sys.stderr)
                return 1
            text = text.replace(anchor, anchor + code if how == "after" else code)
        path.write_text(text, encoding="utf-8")
        print(f"dossaves: patched {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
