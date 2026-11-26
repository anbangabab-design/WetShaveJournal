ObjC.import("Foundation");
function run() {
    const app = Application("com.apple.Notes");
    const excluded = new Set(["最近删除", "Recently Deleted", "废纸篓", "Trash"]);
    const folders = app.folders();
    const results = [];
    const seen = new Set();

    for (let f = 0; f < folders.length; f++) {
        const folder = folders[f];
        let folderName = "";
        try {
            folderName = String(folder.name() || "").trim();
        } catch (e) {
            continue;
        }
        if (excluded.has(folderName)) {
            continue;
        }

        const notes = folder.notes.whose({name: {_beginsWith: "SOTD "}});
        const titles = notes.name();
        if (!titles || titles.length === 0) {
            continue;
        }
        const bodies = notes.body();
        const ids = notes.id();
        if (titles.length !== bodies.length || titles.length !== ids.length) {
            throw Error("读取期间备忘录发生变化，请重新同步。");
        }
        for (let i = 0; i < titles.length; i++) {
            const id = ids[i];
            if (!seen.has(id)) {
                seen.add(id);
                results.push({id, title: titles[i], body: bodies[i]});
            }
        }
    }
    return JSON.stringify(results);
}
